---
title:  "Understanding Proxy Servers, Part 1: Forward Proxying with Squid"
layout: post
tags: proxy squid aws
# description:
---

In this post we'll take a look at how forward proxies work, setting up a working example using [Squid][1].

* Table of contents
{:toc}

# What is a Forward Proxy?
A forward proxy server acts on behalf of a client, forwarding requests from the client to a destination resource, e.g. a server. Typically a forward proxy is an external (internet-facing) server, at or close to the edge of a network, and performs one or more of the following functions:

- **Content filtering** to allow/deny access to internet resources  
- **Hiding the source IP** of the client (requests will appear to originate from the proxy server)
- **Caching requested resources** to improve performance

![Forward Proxy Overview](/assets/img/blog/2021-08-23-forward-proxy-2.svg)


It's important to understand the differences between NAT and a proxy server. NAT operates at layer 3 (IP) of the OSI model, while proxies operate at layers 4 (transport) or 7 (application). In other words, NAT (or more specifically, *source NAT*) simply changes the source IP address of the traffic before passing it to the internet, with no regard for whether the traffic is TCP or UDP, HTTP or HTTPS, etc. A forward proxy, on the other hand, can only work with the protocols it knows, e.g. HTTP. The forward proxy receives the TCP connection from the client, initiates a new TCP connection to the destination server, and then forwards data to/from the client and the destination server.

# Set Up a Forward Proxy with Squid
For this walkthrough, set up two VPCs with public subnets, then launch three Amazon Linux 2 instances with EIPs as in the diagram below (the IPs shown are for illustration purposes only):

![Forward Proxy Setup](/assets/img/blog/2021-08-23-forward-proxy-1.svg)

Install Squid on the forward proxy instance, then enable and start the service:

~~~shell
yum install -y squid
systemctl enable --now squid
~~~

Make sure your proxy instance's security group allows ingress traffic on TCP 3128!
{:.note}

The default Squid configuration in `/etc/squid/squid.conf` is sufficient for our testing, so we won't go into it in any real depth here. To learn more about defining ACL elements and access lists, along with configuring additional features (e.g. caching) in Squid, check out the [Squid docs][2].

In order to visualize how the forward proxy works, let's look at how the client HTTP requests appear to our destination web server both with and without using the proxy server. On the server, we'll use `tcpdump` to display TCP traffic on port 80 (HTTP) without resolving IP addresses or showing full protocol details:

~~~ shell
tcpdump -nq port 80
~~~

On the client, run a curl request against the public IP of the web server (`curl http://<PUBLIC_IP>`) and review the output from tcpdump on the server:

~~~ shell
20:20:25.474564 IP 34.216.74.233.46562 > 10.1.0.163.http: tcp 0
20:20:25.474591 IP 10.1.0.163.http > 34.216.74.233.46562: tcp 0
20:20:25.540975 IP 34.216.74.233.46562 > 10.1.0.163.http: tcp 0
20:20:25.541003 IP 34.216.74.233.46562 > 10.1.0.163.http: tcp 76
20:20:25.541028 IP 10.1.0.163.http > 34.216.74.233.46562: tcp 0
20:20:25.541409 IP 10.1.0.163.http > 34.216.74.233.46562: tcp 294
20:20:25.608021 IP 34.216.74.233.46562 > 10.1.0.163.http: tcp 0
~~~
You'll see the source IP matches the public IP of the client instance. Now try requesting the same page again from the client, this time using `-x` or `--proxy` to specify the proxy server: `curl -x http://<PROXY_IP>:3128 -L http://<PUBLIC_IP>`

~~~ shell
20:22:35.981042 IP 44.226.65.10.44040 > 10.1.0.163.http: tcp 0
20:22:35.981072 IP 10.1.0.163.http > 44.226.65.10.44040: tcp 0
20:22:36.053509 IP 44.226.65.10.44040 > 10.1.0.163.http: tcp 0
20:22:36.053734 IP 44.226.65.10.44040 > 10.1.0.163.http: tcp 225
20:22:36.053754 IP 10.1.0.163.http > 44.226.65.10.44040: tcp 0
20:22:36.054107 IP 10.1.0.163.http > 44.226.65.10.44040: tcp 338
20:22:36.126523 IP 44.226.65.10.44040 > 10.1.0.163.http: tcp 0
~~~
Now the source IP is our proxy server IP, and not the client IP.

This is a good start, but it doesn't really illustrate how a proxy works at the application layer. Instead, let's take a closer look at the HTTP request and headers. While we could do this with an unwieldy [`tcpdump` command][3] while the web server is running, we'll use a simpler option with [`netcat`][4].

Stop the HTTP service on the web server and run `netcat`, configuring it to listen for TCP connections on the now-open port 80:
~~~ shell
systemctl stop httpd
nc -l 80
~~~

On the client, run the curl request against the web server public IP again, and review the output on the server:

~~~ shell
GET / HTTP/1.1
Host: 54.167.193.210
User-Agent: curl/7.76.1
Accept: */*
~~~

This shows us a basic HTTP GET request with standard headers:
- `Host`: the host to which the request is being sent
- `User-Agent`: the application/web browser (Chrome, Mozilla, Safari, etc.) making the request
- `Accept`: the content types can be accepted by the client - `*.*` means any content type

Now repeat the process on the client with the proxy server: `curl -x http://<PROXY_IP>:3128 -L http://<PUBLIC_IP>`

~~~ shell
GET / HTTP/1.1
If-Modified-Since: Tue, 17 Aug 2021 14:18:48 GMT
If-None-Match: "14-5c9c1ff0bf60c"
User-Agent: curl/7.76.1
Accept: */*
Host: 54.167.193.210
Via: 1.1 ip-10-3-0-130.us-west-2.compute.internal (squid/3.5.20)
X-Forwarded-For: 10.3.0.84
Cache-Control: max-age=259200
Connection: keep-alive
~~~

Here we can see a number of additional header fields added to the GET request, including:

- `Via`: the HTTP protocol version (1.1), and the name or alias of the proxy server
- `X-Forwarded-For`: the client IP that made the request - this is shown by default, but can be disabled in the Squid configuration
- `Connection`: whether the connection stays open after the request completes - `keep-alive` means we can use the same connection for additional requests

Remember that Squid will cache pages by default. If `netcat` doesn't display any output when using the proxy, and you get a response from the now-disabled web server, you can disable Squid caching on the proxy instance with `echo "cache deny all" >> /etc/squid/squid.conf`, then restarting the Squid service.
{:.note}

One use case for forward proxies specific to AWS is to allow private connectivity to gateway endpoints from resources outside of a VPC (e.g. on-prem). By creating a load balancer in front of a fleet of Squid proxy instances, and routing requests to S3 or DynamoDB to the Squid proxies, any requests to those gateway endpoints now originate within the VPC. The downside of this setup is that you need to maintain and manage the proxy fleet to ensure connectivity to those services. Check out this [AWS sample solution][5] to learn more.

To access S3 privately from on-prem or from outside of a VPC, [interface endpoints][6] are the recommended solution.
{:.note}

# Wrapping Up
In this first post of a two-part series, we took a look at how forward proxies work, compared forward proxying to NAT, and set up a forward proxy test environment using Squid. In the next post, we'll dig into reverse proxies and compare their functionality with forward proxies.

[1]: http://www.squid-cache.org/
[2]: https://wiki.squid-cache.org/ConfigExamples
[4]: https://linux.die.net/man/1/nc
[3]: https://www.tcpdump.org/manpages/tcpdump.1.html#lbAF
[5]: https://github.com/aws-samples/amazon-s3-gateway-endpoint-proxy
[6]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/privatelink-interface-endpoints.html
