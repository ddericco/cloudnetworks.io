---
title:  "Quick Tips: Stateful Rule Group Capacity in AWS Network Firewall"
layout: post
tags: firewall suricata aws quicktip
# description:
---

[AWS Network Firewall][5] can use a combination of stateless and stateful rule groups for filtering traffic in a firewall policy. Each Network Firewall rule type, stateless and stateful, has a [hard limit][2] of 30,000 capacity 'units' per firewall policy.

Stateless rule capacity is calculated based on the complexity of the rule, and is covered thoroughly in the [AWS docs][1]. Stateful rules groups *generally* have a 1:1 ratio between the number of rules and consumed capacity, but there are a few situations where this can be different.

In this brief post, we'll take a look specifically at stateful rule group capacity with domain lists groups and Suricata rule groups.

* Table of contents
{:toc}

# Domain list rule groups
Let's say you provision a domain list rule group with 100 capacity and configure the group to inspect HTTP traffic. I used the following Python below to generate a bunch of fake domains for easy testing:

~~~ python
for i in range(100):
    print('example'+str(i)+'.com')
~~~

If you try to add all 100 domains, the operation will fail with a `StatefulRules capacity exceeded` error. If you only add 99 domains, the operation will succeed, and the firewall will show a total used capacity of 100. If you try to enable HTTPS inspection as well, the operation will once again fail with the same `StatefulRules capacity exceeded` error.

Domain list rule groups, unlike other stateful rule groups, appear to consume a baseline 1 capacity per traffic protocol inspected, e.g. HTTP and/or HTTPS, as well as an additional capacity per domain and protocol. This is similar to how you'd create separate rules in Suricata for HTTP (`drop http` with `http.host` keyword) and HTTPS (`drop tls` with `tls.sni`).

In other words, to calculate the number of capacity units for a domain list rule group, you can use the following formula:

```
Capacity = (# of domains x # of protocols) + # of protocols
```

In a rule group with **100 capacity**, you can inspect up to *99 domains with HTTP inspection*, or *48 with HTTP and HTTPS*. To inspect all 100 domains with HTTP and HTTPS, you'll need to provision a rule group with **202** capacity. Alternately, you can create a separate rule group per protocol, though you'll need to ensure the domain lists are synced across both groups.

# Suricata IPS rule groups
Suricata rules, like 5-tuple rules, are 1:1 with capacity usage - unlike 5-tuple rules, however, they offer a lot more flexibility and can manage more complex actions with less capacity usage.

As an example, say you wanted to alert whenever a user on your network sent ICMP traffic to Google or CloudFlare DNS. Because 5-tuple rules only accept a single source and destination, you'd need to create three discrete rules for each destination IP:

![5-Tuple Rules in the Console](/assets/img/blog/2021-09-22-5tuple-example.png)

In Suricata, you can also express this with three rules, each using 1 capacity:

~~~
alert icmp any any -> 8.8.8.8/32 any (msg: "SURICATA Detected ICMP to third party";sid:210914;rev:1)
alert icmp any any -> 8.8.4.4/32 any (msg: "SURICATA Detected ICMP to third party";sid:210914;rev:1)
alert icmp any any -> 1.1.1.1/32 any (msg: "SURICATA Detected ICMP to third party";sid:210914;rev:1)
~~~

Alternately, the better approach would be to express this with a combined rule using standard [Suricata syntax][3]:

~~~
alert icmp any any -> [8.8.8.8/32, 8.8.4.4/32, 1.1.1.1/32] any (msg: "SURICATA Detected ICMP to third party";sid:210914;rev:1)
~~~

This rule has the same effect as the others, but only requires 1 capacity unit.

The benefit here becomes obvious when you have multiple repeated rules with overlapping header components like destination addresses - instead of a individual rules per source or destination, you can combine or summarize many rules into one and reduce the amount of consumed firewall capacity. You can also use [variables][4] to define IP and/or port lists when creating the rule via CLI or API.

There aren't any specific limits around rule length in the AWS docs, and I haven't found any specific limits in the Suricata documentation around how long an individual rule can be - that said, test before trying!
{:.note}

# Wrapping Up
In this brief post, we took a quick look at stateful rule groups on AWS Network Firewall, and how to properly calculate stateful rule capacity for domain lists. We also looked briefly at options for consolidating Suricata-compatible rules to reduce consumed capacity.

[1]: https://docs.aws.amazon.com/network-firewall/latest/developerguide/rule-group-capacity.html
[2]: https://docs.aws.amazon.com/network-firewall/latest/developerguide/quotas.html
[3]: https://suricata.readthedocs.io/en/suricata-6.0.0/rules/intro.html#source-and-destination
[4]: https://docs.aws.amazon.com/network-firewall/latest/developerguide/suricata-examples.html#suricata-example-rule-with-variables
[5]: https://aws.amazon.com/network-firewall/
