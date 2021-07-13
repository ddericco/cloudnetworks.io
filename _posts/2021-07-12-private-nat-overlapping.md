---
title:  "Connecting Overlapping VPCs with Private NAT"
layout: post
tags: aws nat transitgateway
# gif: /assets/gif/logo.gif
# image: /assets/img/logo.jpg
# description: "Using private NAT gateway"
---
AWS [recently removed][5] the internet gateway requirement for NAT gateway, essentially creating the ability to use NAT gateway for private traffic. NAT and [AWS PrivateLink][7] are both recommended options for providing connectivity between VPCs with overlapping CIDR blocks. In this post, we'll walk through how this new private NAT gateway functionality fits as a solution, and how it compares to PrivateLink.

# Using Private NAT to Connect Overlapping VPCs
Create a pair of VPCs with the same CIDR range, e.g. `10.0.0.0/16`, and create a public and private subnet in each. Don't worry about creating a NAT gateway as part of the private subnet setup - we'll do this later. Launch an EC2 instance into the public subnet of each VPC. Create a Transit Gateway (TGW) and a separate non-default TGW route table - make sure to disable the "Default route table association" and "Default route table propagation" options. (Hint: check out this [Terraform template][6] to get started.)

![Getting started](/assets/img/blog/2021-07-12-overlapping-vpc-default.png){:.lead data-width="800" data-height="100"}

The overlapping CIDR ranges means we [can't peer these VPCs together][1]. While we can attach both of these VPCs to a TGW and even associate them to the same TGW route table, we won't be able to propagate the routes - the TGW will pick one VPC as the destination for the overlapping CIDR block and drop the overlapping route from the other VPC entirely.

Additionally, both the source and the destination VPC have a default local route with `10.0.0.0/16` as the destination. As a result, any traffic from source instance (e.g. `10.0.1.217`) to the destination instance (`10.0.1.98`) will never leave the source VPC - the default route can't be removed or overridden with more specific routes.

To solve this, we'll use secondary CIDR blocks in the VPCs and static routes in the TGW.

On VPC A, add a small secondary IPv4 CIDR block unique to that VPC. In this example, I'm using RFC 6958 (aka carrier-grade NAT) addresses, but you could easily add a secondary block in the `10.0.0.0/8` range. Remember the [limitations][2] on allowed secondary CIDR blocks. Repeat the process for VPC B, choosing an IPv4 CIDR block that *does not* overlap with the one you just added to A. Make sure to add a subnet for the newly created CIDR blocks and associate the subnet with your private route table!

![Adding a secondary CIDR block](/assets/img/blog/2021-07-12-overlapping-vpc-cidr2.png){:.lead data-width="800" data-height="100"}

At this point, we still won't be able to peer the VPCs - with peering, *none* of the CIDR blocks in a VPC can overlap. We can, however, attach the VPCs to a TGW.

Create the TGW attachments for each VPC *in the secondary (non-overlapping) subnet* and associate them to the same TGW route table. Instead of propagating the routes from the VPCs, create a static route to each attached VPC using the secondary (non-overlapping) CIDR block.

Now that we've updated the TGW route tables, we need to edit the routes for the individual VPCs:

- In the **source** VPC, create a private NAT gateway in the secondary CIDR block subnets. Create a route in the public route table (the one that holds our EC2 instance) to the overlapping VPC's *secondary* CIDR block, with the NAT gateway as the target. In the private route table - the one associated with the subnet that contains the NAT gateway - add a route to the overlapping VPC's *secondary* CIDR block again, this time with the TGW attachment as the target.

- In the **destination** VPC, edit the private route table to add a route to the source VPC's secondary CIDR block, with the TGW attachment as the target.

Once done, our architecture will look like this:

![Full-width image](/assets/img/blog/2021-07-12-overlapping-vpc-added-routes.png){:.lead data-width="800" data-height="100"}

We've now created a path for the NAT'ed traffic to pass from the source to the destination VPC via the secondary CIDR, but we still haven't solved for one key problem: ensuring the traffic reaches the destination instance. Because NAT gateways only perform source NAT, we can't use a NAT gateway to NAT the traffic to the instance in the destination VPC - there's no way for the NAT gateway to determine which instance(s) should receive the traffic. A NAT instance performing destination NAT could solve the problem, but we'd need to manage IP and/or port mappings, scaling up or out to accommodate additional traffic, etc. Instead, we can deploy a Network Load Balancer (NLB), set our overlapping instances as targets, and send traffic from the source instance to the NLB's non-overlapping IP address.

Create an internal NLB in the destination VPC, selecting the subnet in the secondary CIDR block, and create a new target group containing the destination instance ID (this will allow you to preserve the source IP for diagnostic purposes if needed [3]). Now try a `curl` against the internal NLB FQDN:

``` shell
[ec2-user@ip-10-0-1-217 ~]$ curl OverlappingVPC2-NLB-123abc456def789.elb.us-east-2.amazonaws.com
Hello from Instance 2
```

It works! Note that this setup will only allow the source to initiate a connection to the destination VPC - if you need bidirectional traffic from the second overlapping VPC to the first, you'd need to essentially mirror this setup (NAT gateway in the second VPC, NLB targeting the instance in the first VPC). The diagram below shows the traffic flow:

![Full-width image](/assets/img/blog/2021-07-12-overlapping-vpc-final.png){:.lead data-width="800" data-height="100"}

# Comparing Private NAT with PrivateLink
If you've worked with AWS networking constructs before, you may be thinking, "If I need to deploy an NLB, and this setup only provides unidirectional access, why not use PrivateLink instead?"

- If you use TGW with AWS Network Firewall or Gateway Load Balancer for centralized traffic inspection/filtering, all traffic needs to pass through the TGW to an inspection VPC before being routed to its destination. PrivateLink would completely bypass the TGW (and your security stack) altogether.
- If you need source IP preservation with private NAT, you can specify the NLB targets by instance ID or IP address, with [certain limitations][8] - note the source IP will be the NAT gateway IP, not the source instance IP. With PrivateLink, the source IP is *always* the private IP address of the NLB.

Cost is another consideration here - let's imagine a scenario where we need to pass 100GB of data from one overlapping VPC to another in a month. Since both the private NAT and the PrivateLink solutions require NLB to be deployed, we'll zero out those costs for now. We'll also assume at least three AZs per VPC, and one NAT gateway per AZ, for high availability. All pricing data comes from the [AWS Pricing Calculator][9] as of the time this post was written:

| Service | Total Cost |
|---------|------------|
| NAT Gateway usage and data processing costs (source VPC) | $103.05/month  |
| TGW per attachment (source and destination VPC) and data processing costs | $77.00/month |
| Total | **$180.05/month** |

| Service | Total Cost |
|---------|------------|
| Total PrivateLink endpoints and data processing cost (source VPC) | $22.90/month |
| Total | **$22.90/month** |

From a cost standpoint, PrivateLink is clearly the optimal solution for this admittedly  simplified example. There may be other considerations besides the ones above that you'll need to take into account when deciding which solution to use.


[1]: https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-basics.html#vpc-peering-limitations
[2]: https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Subnets.html#add-cidr-block-restrictions
[3]: https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#client-ip-preservation
[4]: https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html#how-route-tables-work
[5]: https://aws.amazon.com/about-aws/whats-new/2021/06/aws-removes-nat-gateways-dependence-on-internet-gateway-for-private-communications/
[6]: /assets/templates/2021-07-12-overlapping-vpcs.tf
[7]: https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/aws-privatelink.html
[8]: https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html#client-ip-preservation
[9]: https://calculator.aws/#/
