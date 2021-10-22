---
title:  "Intro to IPv6 in AWS"
layout: post
tags: aws ipv6 vpc dns
# description:
---

During the AWS DC Summit in September, AWS announced upcoming support for [IPv6-only networking][5] as part of the keynote speech. If, like me, you haven't paid much attention to IPv6 before, you're not alone - as of October 2021, Google showed that [only 36% of its users][4] were able to access their services over IPv6. Even Amazon.com doesn't appear to support IPv6 for customer traffic!

The benefits of IPv6 -  a virtually inexhaustible number of available IPs, no more NAT, no more dealing with overlapping CIDR blocks, etc. - have been extensively covered elsewhere (I'm a fan of [this walkthrough][7] from the Internet Society). For many network admins that I've talked with, IPv6 is one of those "we'll deal with it when we have to" scenarios and not an immediate area of focus. This announcement from AWS, however, could mean that IPv6-only network designs in AWS will see broader adoption in the not-too-distant future.

In this post, we'll take a look at the basics of how IPv6 is implemented in an AWS VPC.

* Table of contents
{:toc}

# IPv6 in VPC-land
As a refresher, IPv6 uses 128-bit addresses in a hexadecimal format of 32 hex digits, e.g. `2600:1f14:1ba:ca00:0000:0000:0000:0000/56` (or `2600:1f14:1ba:ca00::/56` for short). For the purposes of this discussion, we're going to focus on two types of IPv6 addresses:

- **Global unicast**: like public IPv4 addresses, an organization requests a unique block of these IPv6 global unicast addresses from a regional internet registry (RIR). These addresses can only be used by that organization.
- **Unique local** (prefix `fd00::/8`): analagous to IPv4 private address space, these addresses can be used without registering with an RIR. Multiple organizations can use these addresses, and they can overlap with others.

IPv6 also allocates specific ranges for link-local addresses (`fe80::/10`) and multicast addresses (`ff00::/8`), but we won't dig into those in any depth here.
{:.note}

When you add an IPv6 CIDR block to a VPC, AWS provisions a /56 from the global unicast address range for you to use.

![image](/assets/img/blog/2021-10-21-ipv6-vpc.png)

Because humans are bad at conceptualizing large numbers (see the [relevant XKCD][1]), I took a stab at trying to understand how many addresses are actually available in a /56 and came up with the [following estimate][3]:

```
  2^(128-56)      # IPv6 addresses in a /56
/ 108.3 billion   # estimated number of people who have ever lived

= 43.54 billion addresses per capita
```

In other words, you could give 43 billion IP addresses to every human who's ever lived, and *still* have addresses left over in your VPC for your Kubernetes cluster.

Within each VPC, you can allocate a /64 prefix per subnet (that's 18 quintillion addresses per subnet, for those still keeping track) for a total of up to 256 IPv6 subnets. While you're not able to specify the IPv6 block you receive from AWS (the range will depend partly on the region), you can specify the subnet mask of the /64.

![image](/assets/img/blog/2021-10-21-ipv6-subnet.png)

Similar to IPv4, you can also bring your own IPv6 (BYOIP) and allocate individual blocks to VPCs as needed.

Local Zones do not currently support IPv6.
{:.note}

Once you've added an IPv6 CIDR block to the VPC during or after creation, enabling IPv6 for your resources is fairly straightforward - you follow the same basic setup as you would with an IPv4 network: create subnets, add routes, update security groups, etc. These steps are well documented and can be found in the [AWS docs][2].

# Using IPv6 with networking tools
Most of the common network testing tools (`ping`, `curl`, `iperf`, `dig`) support IPv6 with an additional command line flag such as `-6` - if in doubt, check the man pages. Annoyingly, curl will not accept an IPv6 address unless it's included in brackets:

~~~ shell
[ec2-user@ip-172-31-23-35 ~]$ curl -6 2600:1f18:77:e500:c75f:9951:e002:b2fd
curl: (3) URL using bad/illegal format or missing URL
[ec2-user@ip-172-31-23-35 ~]$ curl -6 [2600:1f18:77:e500:c75f:9951:e002:b2fd]

<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
...
~~~

If you're in too much of a hurry to use a dash, you can simply use `ping6` instead of `ping -6`.
{:.note}

# IPv6 and the Route 53 Resolver
When using a tool like `dig` to troubleshoot DNS issues with IPv6 in AWS, you'll want to think about whether you're using IPv6 to query a DNS server and/or whether you're querying for an IPv6 record type. A DNS server configured with only IPv4 addresses can still respond to queries for IPv6 records, for example, but won't be able to respond to IPv6 traffic. You can use the following options for IPv6:

~~~ shell
dig -6 # Use IPv6 only to resolve queries
dig -t AAAA # Specifies the AAAA IPv6 record type
~~~

DNS resolution in an IPv4 VPC happens at the .2 resolver (aka Route 53 Resolver) - you can also use 169.254.169.253 to resolve DNS queries. Both of these addresses will resolve IPv6 AAAA records, but what about DNS resolution over IPv6? Instead of an address from the VPC CIDR, the the Route 53 Resolver uses a *unique local* IPv6 address, `fd00:ec2::253`. You can query this like any other DNS resolver:

~~~ shell
$ dig -6 -t AAAA netflix.com @fd00:ec2::253
~~~

Suprisingly, querying AAAA records for amazon.com returns no results:

~~~ shell
$ dig -t AAAA amazon.com +noall +answer

; \<<>> DiG 9.10.6 \<<>> -t AAAA amazon.com +noall +answer
;; global options: +cmd
~~~

Other points to keep in mind when working with DNS and IPv6:

- By default most Linux AMIs (AL2, Ubuntu 20.04, RHEL 8) only include the .2 resolver in `/etc/resolv.conf`. If you want to use IPv6 to resolve DNS queries, you'll need to manually add it to your list of resolvers, or specify it when using `dig` using the `@` option.
- The VPC DNS resolver on IPv6 is only available to [Nitro instances][11] - if you're testing IPv6 on a t2.micro, you won't be able to communicate with the IPv6 endpoint.

# IPv6 and private (or not) subnets
We've talked about how AWS allocates IPv6 addresses from the global unicast address space. Unlike IPv4, where you need to assign a public IP or elastic IP to an EC2 instance for it to be publicly reachable, EC2 instances with IPv6 addresses will be publicly reachable by default. Unique local addressing isn't available for a VPC (as we've seen, AWS uses it for internal services like DNS), so how can we leverage IPv6 for resources that shouldn't be reachable over the internet?

- **Use route table isolation**: by removing the route to `::/0` with the internet gateway as the target, the EC2 instance is no longer reachable from the internet over IPv6. Note the instance also won't be able to initiate connections to internet resources over IPv6, though you can still create IPv6 routes to other destinations (peered VPCs, TGW, etc.)
- **Use security groups & NACLs**: security group and NACL rules can use IPv4 or IPv6 as a source, but not both. In addition to route-level isolation, this level of granularity allows us to create specific rules to allow or deny IPv6 traffic without impacting IPv4.
- **Use an [egress-only internet gateway][6]**: for IPv6 resources that need to reach out to the internet for software installation, patching, package updates, etc. Functionally similar to a NAT gateway in that it allows  outbound traffic flows initiated from a VPC, but not inbound from the internet.

Replace "egress-only internet gateway" with "NAT gateway" and all of these concepts are the same for IPv4 instances with public or elastic IP addresses.
{:.note}

# IPv6 with NTP and EC2 IMDS
In addition to the Route 53 Resolver, AWS earlier this year launched IPv6 support for the EC2 Instance Metadata Service (IMDS) and network time protocol (NTP). Like the IPv6 Route 53 Resolver, these services:

- Use unique local IPv6 addresses
- Can only be accessed from Nitro instances
- Are not enabled by default

~~~
fd00:ec2::254 # IMDS
fd00:ec2::123 # NTP
~~~

By now you'll probably have noticed that for all of these IPv6 endpoints, the final quartet of the IPv6 address matches the final quartet of the IPv4 address (i.e. `169.254.169.123` for IPv4 NTP, `fd00:ec2::123` for IPv6 NTP). This should make them easier to remember when moving to IPv6.
{:.note}

Enabling NTP over IPv6 is as straightforward as adding the address `fd00:ec2::123` to your NTP client configuration (this will depend upon the OS - see [here][10] for a Linux walkthrough). To test without making changes to your configuration, use the `ntpdate` command:

~~~ shell
$ ntpdate -q fd00:ec2::123
server fd00:ec2::123, stratum 3, offset 0.000878, delay 0.02614
21 Oct 18:56:23 ntpdate[64333]: adjust time server fd00:ec2::123 offset 0.000878 sec
~~~

Enabling IPv6 for the IMDS is a bit more complicated. Instead of making changes at the OS level, you'll need to edit the instance metadata options for the instance - this can only be done via CLI or API using the [modify-instance-metadata-options][8] command:

~~~ shell
$ aws ec2 modify-instance-metadata-options \
    --instance-id i-1234567898abcdef0 \
    --http-protocol-ipv6 enabled
~~~

Once done, you can query the IMDS using the IPv6 address - don't forget to put the address in square brackets and include the `-6` flag:

~~~ shell
$ curl -6 [fd00:ec2::254]/latest/meta-data
~~~

This also works if you have [IMDSv2][9] enabled on your instance (and you should):

~~~ shell
$ TOKEN=`curl -X PUT "http://[fd00:ec2::254]/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
$ curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://[fd00:ec2::254]/latest/meta-data/
~~~

# Wrapping up
In this post we took a look at the basics of operating with IPv6 in a single VPC, including how addressing works and hwo to leverage IPv6 endpoints for specific network functions. In a future post we'll look at taking a test network setup and extending it to implement IPv6.

[1]: https://xkcd.com/2091/
[2]: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6.html
[3]: https://www.wolframalpha.com/input/?i=%282%5E%28128-56%29%29%2Fhow+many+humans+have+ever+lived
[4]: https://www.google.com/intl/en/ipv6/statistics.html
[5]: https://www.crn.com/slide-shows/cloud/9-bold-statements-from-aws-public-sector-vp-max-peterson/9
[6]: https://docs.aws.amazon.com/vpc/latest/userguide/egress-only-internet-gateway.html
[7]: https://www.internetsociety.org/deploy360/ipv6/faq/
[8]: https://docs.aws.amazon.com/cli/latest/reference/ec2/modify-instance-metadata-options.html
[9]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
[10]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html#configure-amazon-time-service-amazon-linux-IPv6
[11]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-types.html#ec2-nitro-instances
