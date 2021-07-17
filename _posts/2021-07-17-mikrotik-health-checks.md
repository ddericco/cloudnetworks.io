---
title:  "Three Ways to Perform Health Checks/Monitoring in RouterOS"
layout: post
tags: mikrotik routeros pihole monitoring
# gif: /assets/gif/logo.gif
# image: /assets/img/logo.jpg
description: "Learn how to configure ICMP, HTTP(S), and DNS health checks on RouterOS"
---
I've used [Pi-hole][1] on a Raspberry Pi as a DNS resolver and adblocker in my home network for several years. While performing some recabling recently I accidentally disconnected the Pi-hole from the core switch, much to the chagrin of everyone else using the internet in the house.

My home router runs Mikrotik RouterOS, which offers a scripting engine that can be used to automate device configuration, perform scheduled tasks, etc. I wanted to create a script to check if the Pihole was available and if not, update the local DNS to remove the Pi-hole until it was online again. This wouldn’t eliminate the need to disable/enable WiFi on client devices, but it would 1) restore the network to a working state automatically and 2) notify me that there was a problem.

Using this problem as an example, let's take a look at several of the monitoring tools available in RouterOS and how to use them in a script. If you're the impatient type, or just looking for a DNS monitoring solution for Pi-hole, skip ahead to the [end][7].

* Table of contents
{:toc}

## 1: ICMP health checks with `netwatch`
[Netwatch][2] is a tool that sends ICMP traffic at a user-defined interval to target IP addresses on a network. In addition to sending and monitoring ping responsiveness, Netwatch allows you to define and trigger scripts when a host responds (`up-script`) or doesn't respond (`down-script`). Using the Pi-hole as an example, we can configure Netwatch to run a script to change the DNS assigned via DHCP when the Pi-hole doesn't respond to pings.

From the RouterOS console, first define the scripts (using `192.168.88.2` as an example):
```
# Set DHCP-provided DNS to CloudFlare - subsitute your preferred provider
/system script add name=remove-pihole-dns\
source={/ip dhcp-server network set 0 dns-server=1.1.1.1; /log warning "Updating DNS to third-party"}
# Set DHCP-provided DNS to the Pi-hole IP address
/system script add name=add-pihole-dns\
source={/ip dhcp-server network set 0 dns-server=192.168.88.2; /log info "Updating DNS to Pi-hole"}
```
Now we can configure Netwatch, referencing the scripts we just created:
```
/tool netwatch add host=192.168.88.2\
interval=60s\ # Timeout between pings
timeout=10s\ # Timeout before a host is considered down
up-script=add-pihole-dns\
down-script=remove-pihole-dns
```
To test, block ICMP traffic in your Pi-hole firewall (or simply unplug it for a more authentic experience). After 60 seconds, you'll see the following in the router logs (use `/log print follow` to see updates in real time):

```
15:16:57 script,warning Updating DNS to third-party
15:16:57 system,info dhcp network changed by admin
```

A quick WiFi down/up later and your device should receive the updated DNS configuration via DHCP.

This is good for a baseline, but as a Pi-hole-specific health check it leaves a lot to be desired. If the Pi-hole services (e.g. `pihole-FTL` and `lighttpd`) were to crash or stop responding to DNS queries, the Pi itself would still respond to pings and never trigger the failover action. To that end, let's look at how to script a health check against the Pi-hole web console (better option) and, more importantly, ensure that DNS queries to the Pi-hole resolve successfully (best option!).

## 2: HTTP(S) health checks with `fetch`
RouterOS doesn't support `curl`, but does provide a similar tool called [fetch][3]. We can use this to perform an HTTP request against the Pi-hole console, e.g.:

`/tool fetch url="http://192.168.88.2/index.html"`

A couple of pointers for using fetch:
- Make sure to specify either HTTP or HTTPS in the URL - an IP or bare domain will return `invalid URL protocol`.
- Similarly, you need to specify an .html file in the URL. *http://google.com* will return `invalid URL`, but *http://google.com/index.html* will work fine (if in doubt, try index.html).

You can also use fetch to perform POST/GET requests, which can be useful for integrating with notification or incident management systems (e.g. PagerDuty) - here's how you would send a message to a [Slack webhook][4]:

```
/tool fetch mode=https http-method=post http-header-field="Content-Type: application/json" http-data="payload{\"text\":\"Updating DNS to third-party\"}" url="https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
```

Conveniently, the Mikrotik wiki has an example script that gets us most of the way there. We'll update this to change the DHCP-provided DNS server as before and add error handling. We'll also add an `if` statement to check if the Pi-hole is already set as the provided DNS server - this will prevent unnecessary configuration changes every time script runs.

There are probably multiple ways this can be completed in script form - these are some examples I've found to work. RouterOS scripting is beyond the scope of this post, but you can find plenty of additional examples from the [wiki][5]).
{:.note}

Here's the final script (use `/system script add` to add it):
```
:do {
  /tool fetch url="http://192.168.88.2/index.html";
  :if ([/ip dhcp-server network get 0 dns-server] !=192.168.88.2) do={
    :log info "Updating DNS to Pi-hole"
    /ip dhcp-server network set 0 dns-server=192.168.88.2;
  }
} on-error={
  :if ([/ip dhcp-server network get 0 dns-server] !=1.1.1.1) do={
    :log info "Updating DNS to third-party"
    /ip dhcp-server network set 0 dns-server=1.1.1.1;
};
```

Unlike `netwatch`, scripts need to be scheduled in order to run at regular intervals. Use [`/system scheduler`][8] to set them up.
{:.note}

This is better than a simple ping check, and we've added some useful functionality, but it still doesn't tell us if DNS queries will resolve successfully. For that, we'll need to use `resolve`.

## 3. DNS health checks with `resolve`
[Resolve][6] is similar to dig or host - as the name suggests, you use it resolve DNS hostnames to the corresponding IPs. Unlike the other tools we've looked at, `resolve` is a script command and will not output to the console by default. To see the results of a query in the console, you need to use `put`, e.g.:

`put [:resolve google.com server=192.168.88.2]`

If the specified DNS server is working correctly, this will return an IP address; if not, the command will return `dns server failure`.    

The resulting script is structured similarly to the HTTP health check script - here's what it does:

- Run a `resolve` against a target domain of our choice, e.g. google.com
  - Check if the DHCP-provided DNS is already set to the Pi-hole - if not, update it
  - Note that because `resolve` is used in a script, we don't need to `put` the output to the console
- If `resolve` fails with an error, log a warning and set the DNS to the third-party

```
:do {
  :resolve google.com server=192.168.88.2
  :log info "Successfully resolved DNS query against Pi-hole";
  :if ([/ip dhcp-server network get 0 dns-server] !=192.168.88.2) do={
    :log warning "Updating DNS to Pi-hole"
    /ip dhcp-server network set 0 dns-server=192.168.88.2;
  }
} on-error={
  :log error "Failed to resolve DNS query against Pi-hole";
  :if ([/ip dhcp-server network get 0 dns-server] !=1.1.1.1) do={
    :log info "Updating DNS to third-party"
    /ip dhcp-server network set 0 dns-server=1.1.1.1;
};
```
This is the best option for our use case since it actually checks the functionality we want!

## Wrapping up
Having the proper health checks in place is critical to monitoring your networks - cloud or terrestrial - and being able to quickly respond to any outages. The biggest consideration is making sure your health checks align with what you actually care about. To use our example here: having an ICMP health check in place when we really care about DNS resolution is effectively useless. When a problem does occur, a bad health check *can and probably will* feed you a bunch of noise that 1) won't help isolate the issue and 2) will delay you and your teams from getting to a quick resolution.

In this post we looked at a few of the tools available in RouterOS to perform three basic types of health checks, using a Pi-hole as an example. For more detailed explanations of these tools and the full functionality available, check out the [Mikrotik wiki][5].


[1]: https://pi-hole.net/
[2]: https://wiki.mikrotik.com/wiki/Manual:Tools/Netwatch
[3]: https://wiki.mikrotik.com/wiki/Manual:Tools/Fetch
[4]: https://api.slack.com/messaging/webhooks
[5]: https://wiki.mikrotik.com/wiki/
[6]: https://wiki.mikrotik.com/wiki/Manual:Scripting#Global_commands
[7]: ./#3-dns-health-checks-with-resolve
[8]: https://wiki.mikrotik.com/wiki/Manual:System/Scheduler
