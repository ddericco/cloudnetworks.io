---
title:  "Setting up Private DNS with AWS PrivateLink"
layout: post
tags: aws privatelink dns
# description:
---
[Private DNS for AWS PrivateLink][1] is a feature that allows you to create private, custom DNS names for internal or third-party PrivateLink services. In this post, we'll look at an example using [WhySirens.com][2], the premier webapp that tells you why you're currently hearing police, fire, or ambulance sirens.

As part of the WhySirens service offering, customers (consumers) with an AWS presence can access their WhySirens data via PrivateLink. Currently WhySirens service consumers need to either use the default endpoint DNS name - and potentially recode their applications to do so - or configure a private hosted zone with ALIAS records if they want to resolve a friendly name like `app.whysirens.com` to the PrivateLink endpoint.

Instead of making their service consumers do the work, let's walk through how WhySirens can create a privately-resolvable DNS name, i.e. `app.whysirens.com`, for their consumers to use to connect to the PrivateLink service.

* Table of contents
{:toc}

## Review the setup
In the consumer account, we'll review the existing VPC endpoints. Make a note of the DNS names associated with the endpoint in the console:

![Endpoint DNS names](/assets/img/blog/2021-07-24-pldns-review.png){:.lead data-width="800" data-height="100"}

You can also use the CLI:

~~~ shell
$ aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[*].DnsEntries'
~~~

If you have multiple endpoints in your consumer VPC, it might be challenging to parse the output. To filter to VPC endpoint service interfaces, use the following filters: `aws ec2 describe-vpc-endpoints --filters "Name=vpc-endpoint-type,Values=Interface" "Name=service-name,Values=*vpce-svc*"`
{:.note}

Doing a `dig` on the first resulting DNS name shows the corresponding endpoint IP addresses within the consumer VPC:

~~~ shell
$ dig +short vpce-04f8bfb4666fccc60-nkf8dj4z.vpce-svc-0c07381cf1948854e.us-east-1.vpce.amazonaws.com
172.31.6.226
172.31.46.173
~~~

In addition to the main DNS entry, our PrivateLink endpoint also has AZ-specific DNS records (us-east-1a, us-east-1b, etc.) - performing a `dig` against those will return the individual IPs associated with those ENIs.

The DNS records created with a VPC endpoint are *not private* - querying those records from a host outside of the VPC (e.g. your local machine) will return the private IP addresses. This might seem like a security risk, but in practice there's not much an attacker can do with this information. There's nothing in the record that ties the IP address to an AWS account, IAM role, VPC, or other identifying data. An attacker would also need to know the entire (randomized) FQDN of the endpoint to even query it!
{:.note}

Performing a query against `app.whysirens.com` returns an NXDOMAIN:

~~~ shell
$ dig app.whysirens.com
# <...output truncated>
;; Got answer:
;; -\>\>HEADER\<\<- opcode: QUERY, status: NXDOMAIN, id: 1586
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1
~~~

## Add private DNS in the provider account
In the *provider account* console, select the endpoint service, then under Actions, choose "Modify private DNS name":

![Modify the endpoint private DNS name](/assets/img/blog/2021-07-24-pldns-provider-enable.png)

Enable the private DNS name by entering the domain - in this example, we want consumers to use `app.whysirens.com` - and save the changes:

![Add the private DNS name](/assets/img/blog/2021-07-24-pldns-provider-add.png)

Alternately, from the CLI:
~~~ shell
# List the current endpoint services - note the ServiceId
aws ec2 describe-vpc-endpoint-service-configurations
# Add the private DNS name
aws ec2 modify-vpc-endpoint-service-configuration --service-id vpce-svc-0c07381cf1948854e --private-dns-name app.whysirens.com
~~~

In order to verify that you actually own the domain being used for the private DNS, AWS provides you with a TXT  record to add to your domain's DNS servers (TXT records - literally "text" records - are commonly used for domain ownership verification, spam prevention, etc.). AWS then will periodically query your domain's DNS servers for the presence of this record. You won't be able to use the private DNS name until this domain name verification check completes successfully.

![console image here](/assets/img/blog/2021-07-24-pldns-provider-verify.png)

The instructions for adding the TXT record will differ depending upon your DNS provider - for a Route 53 managed domain, you can add a TXT record in the console, or upload a [JSON file via CLI][8]. Other generic instructions can be found [here][7].

**Route 53**: Because TXT records are [double-quoted strings][4], you'll need to escape the quotation marks in the resource record value field, e.g. `"\"mystring\""`, when creating the JSON file.
{:.note}

Verify that the TXT record was created successfully by performing a `dig` against the FQDN - you should see the string value returned:

~~~ shell
$ dig +short -t TXT _vdufhro3v7skf8zxqqp5.whysirens.com
"vpce:x17K4W0MTcUJR42my2xm"
~~~

Once the TXT record is created, AWS will need to complete the verification process in order to enable the private DNS name. AWS doesn't provide a time estimate, but in my experience this usually takes no more than 15 minutes at most if you've created the TXT records correctly (this is where you get up and get a coffee, water, etc.). You can also manually initiate the verification process from the [console or CLI][3].

## Enable private DNS in the consumer account
Now that the private DNS name enabled in the provider account, we can enable the private DNS name for the endpoint in the consumer account as well.

![Enable private DNS in the consumer account](/assets/img/blog/2021-07-24-pldns-enable-consumer.png){:.lead data-width="800" data-height="100"}

From the CLI:
~~~ shell
aws ec2 modify-vpc-endpoint --vpc-endpoint-id vpce-04f8bfb4666fccc60 --private-dns-enabled
~~~

The status in the console (`"State"` in the CLI) will change to "pending" - this won't interrupt connectivity to the existing DNS names - and then to "available" once the change completes. Performing a `dig` from an EC2 instance in the VPC to `app.whysirens.com` will now show the endpoint IPs:

~~~ shell
$ dig +short app.whysirens.com
172.31.6.226
172.31.46.173
~~~

Unlike the default endpoint DNS record, this private DNS name will **NOT** be resolvable from outside of the VPC. This is because the private DNS name is created in an AWS-managed Route 53 private hosted zone associated with the VPC. As the service provider, the WhySirens team can use the same private DNS name for multiple endpoint services if needed.

## Wrapping Up
In this post we walked through setting up a private DNS name for a PrivateLink service. While the consumer account could set up a private hosted zone `app.whysirens.com` with an ALIAS record to the endpoint, this removes the burden from the customers and provides a better experience with the WhySirens service.

A few final thoughts:

- Keep in mind the [documented considerations][6] around the domain name verification process - you'll need to complete this process for *each endpoint service*, even if they share the same private DNS name.
- Performing the domain verification against a wildcard domain, e.g. `*.app.whysirens.com`, will create a resolvable private DNS name for both the domain and any subdomains (`app.whysirens.com`, `my.app.whysirens.com`, etc.)
- Because this setup creates a private hosted zone associated with the endpoint VPC, other VPCs won't be able to natively resolve the private DNS name. For cross-VPC resolution via peering or Transit Gateway, check out this AWS [blog post][5].


[1]: https://aws.amazon.com/about-aws/whats-new/2020/01/aws-privatelink-supports-private-dns-names-internal-3rd-party-services/
[2]: http://whysirens.com
[3]: https://docs.aws.amazon.com/vpc/latest/privatelink/verify-vpc-endpoint-service-dns-name.html
[4]: https://datatracker.ietf.org/doc/html/rfc1464
[5]: https://aws.amazon.com/blogs/networking-and-content-delivery/integrating-aws-transit-gateway-with-aws-privatelink-and-amazon-route-53-resolver/
[6]: https://docs.aws.amazon.com/vpc/latest/privatelink/verify-domains.html#considerations
[7]: https://docs.aws.amazon.com/vpc/latest/privatelink/dns-txt-records.html#generic-procedures-for-other-dns-----------------providers
[8]: https://aws.amazon.com/premiumsupport/knowledge-center/simple-resource-record-route53-cli/
