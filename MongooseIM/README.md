# MongooseIM

We believe that the best Enterprise Instant Messaging Solution is the one built specifically for your client. With [MongooseIM](MIM), we offer the flexibility of a bespoke in-house built chat system with the ease of use, reliability and scalability of a battle-tested enterprise solution.

  * [TL;DR](#tldr)
  * [Introduction](#introduction)
  * [Common parameters](#common-parameters)
  * [Monitoring results](#monitoring-results)
  * [Deployments](#deployments)
  * [Expose the XMPP service](#expose-the-xmpp-service)
    * [Public XMPP IP with a load balancer](#public-xmpp-ip-with-a-load-balancer)
    * [Direct access via external worker node IPs](#direct-access-via-external-worker-node-ips)

## TL;DR

MongooseIM is a mobile messaging platform with a focus on extensibility, performance and scalability.

```sh
helm repo add mongoose https://esl.github.io/MongooseHelm/
helm install my-mongooseim mongoose/mongooseim --set replicaCount=1
```

## Introduction

This chart will install a MongooseIM cluster composed of a single node (set `replicaCount=n` for more nodes), sitting behind a regular k8s load-balancer, with a default sane configuration.

To uninstall, simply run `helm uninstall my-mongooseim`, where `my-mongooseim` is the release name you've given to your installation.

## Common parameters

| Parameter          | Description                                          | Default      |
|--------------------|------------------------------------------------------|--------------|
| `nodeName`         | Name of the nodes as containers                      | `mongooseim` |
| `nodeCookie`       | Cookie to be used by the BEAM                        | `mongooseim` |
| `replicaCount`     | Default number of replicas to be clustered           | `1`          |
| `loadBalancerIP`   | Exposed external IP address for the Load Balancer, it exposes the XMPP TCP interface | not set (will be automatically assigned) |
| `mimConfig`        | User-given `mongooseim.toml` configuration file      | not set (internal default, check sources) |
| `vmConfig`         | User-given `vm.args` file (used for tweaking the Erlang VM itself) | not set (internal default, check sources) |
| `nodeport.enabled` | Whether the k8s nodeport service is desired          | `false`      |

NOTE: `vmConfig` and `mimConfig` should be given using helm's `--set-file` directive, as below:

```sh
helm install mim mongoose/mongooseim --set-file mimConfig=<path-to-mim-toml-config-file.toml>
```

## Monitoring results

When working with a Kubernetes cluster it's convenient to see the results of the actions taken. In order to do that, let's start a terminal window and run:

```sh
watch kubectl get node,pod,pv,pvc,sts,svc
```

This is going to be our monitoring window. We'll input commands in another terminal.

## Deployments

MongooseIM pods will automatically initiate communication between one another and form a cluster, but they require a DNS service for that. We'll use a [Kubernetes headless service](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services) and [StatefulSet stable network IDs](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-network-id) to provide DNS for our cluster members, described in `mongoose-svc.yaml`

Assuming we've installed MongooseIM with a command as follows:

```sh
helm install mim mongoose/mongooseim --set replicaCount=3
```

A `mongooseim` StatefulSet should appear in the monitoring window, followed by its pods. It will take a few minutes for all the pods to start and become ready to serve traffic:

```sh
NAME               READY     STATUS    RESTARTS   AGE
pod/mongooseim-0   1/1       Running   0          4m
pod/mongooseim-1   1/1       Running   0          2m
pod/mongooseim-2   1/1       Running   0          1m

NAME                          DESIRED   CURRENT   AGE
statefulset.apps/mongooseim   3         3         4m
```

Once all the pods are up we can check the cluster status:

```sh
$ kubectl exec mongooseim-0 -- /usr/lib/mongooseim/bin/mongooseimctl mnesia running_db_nodes
['mongooseim@mongooseim-2.mongooseim.default.svc.cluster.local',
 'mongooseim@mongooseim-1.mongooseim.default.svc.cluster.local',
 'mongooseim@mongooseim-0.mongooseim.default.svc.cluster.local']
```

The above command should return the same list of nodes (possibly in different order) no matter whether we exec it on `mongooseim-0`, `mongooseim-1`, or any other member of the cluster.

If we want to add or remove nodes, we can simply run the following command, where `N` is the new desired count:

```sh
helm upgrade mim mongoose/mongooseim --set replicaCount=N
```

## Expose the XMPP service

There are two basic ways to expose the XMPP service to public internet. The first and easiest is using a public IP provided by your k8s cluster. The second, somewhat more involved and less convenient, but at the same time cheaper, is to use the public IPs of the Kubernetes worker nodes.

### Public XMPP IP with a load balancer

The most straightforward way to expose the service is via a load balancer of the cluster provider (this is the chosen default for this helm package). This Load Balancer is defined in `mongoose-svc-lb.yaml`.

It will take up to a few minutes to get an IP address from the provider's pool of public addresses, but once that's done, we should see it in the monitoring window:

```sh
NAME                   TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                                        AGE
service/kubernetes     ClusterIP      10.43.240.1    <none>          443/TCP                                        2h
service/mongooseim     ClusterIP      None           <none>          4369/TCP,5222/TCP,5269/TCP,5280/TCP,9100/TCP   15m
service/mongooseim-lb  LoadBalancer   10.43.247.53   35.204.210.47   5222:31810/TCP                                 1m
```

The service should now be reachable from any host with access to the internet (including our local machines). A simple test would be running telnet and pressing Ctrl-D to send the end of file symbol:

```sh
$ telnet 35.204.210.47 5222
Trying 35.204.210.47...
Connected to 47.210.204.35.bc.googleusercontent.com.
Escape character is '^]'.
<?xml version='1.0'?><stream:stream xmlns='jabber:client'...
```

Success! Since we're connecting with `telnet`, not an XMPP client, the connection dies instantly, but we got the XMPP stream initiation element from the server - the service is up, running, and reachable from everywhere.

In case we don't want to use this access method to the service we can tear the load balancer down with:

```sh
kubectl delete svc mongooseim-lb
```

### Direct access via external worker node IPs

The LoadBalancer is the more convenient, but also the more expensive way of publishing a service. We can also access our MongooseIM instances by using Kubernetes worker nodes' external IP addresses.

In order to do that, we first have to create a NodePort service:

```sh
helm upgrade mim mongoose/mongooseim --set nodeport.enabled=true
```

After a while it should appear in our monitoring window:

```sh
NAME                         TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                                        AGE
service/kubernetes           ClusterIP   10.43.240.1    <none>        443/TCP                                        3h
service/mongooseim           ClusterIP   None           <none>        4369/TCP,5222/TCP,5269/TCP,5280/TCP,9100/TCP   1h
service/mongooseim-nodeport  NodePort    10.43.253.16   <none>        5222:32709/TCP                                 41s
```

The last line tells us that the service will be available on the port 32709 of Kubernetes workers' external interfaces. We can find their external addresses (for example) with:

```sh
$ kubectl describe nodes | grep ExternalIP
  ExternalIP:  35.204.145.243
  ExternalIP:  35.204.114.176
  ExternalIP:  35.204.144.193
```

However, unlike with LoadBalancer, using NodePort we have to manually open the relevant port (32709 in this case) in the firewall, For example for `gcloud` (see [Creating a Service of type NodePort](https://cloud.google.com/kubernetes-engine/docs/how-to/exposing-apps#creating_a_service_of_type_nodeport) for the source of this command):

```sh
gcloud compute firewall-rules create mongooseim-c2s-nodeport --allow tcp:32709
```

We can now check that the service is available on the public internet (e.g. our machine) in a similar fashion to testing the LoadBalancer setup (run `telnet` and immediately type Ctrl-D):

```sh
$ telnet EXTERNALIP 32709
Trying EXTERNALIP...
Connected to ...
Escape character is '^]'.
<?xml version='1.0'?><stream:stream xmlns='jabber:client'...
```

Again, the opening `<stream>` element means we've successfully connected to our MongooseIM cluster.

[MIM]: https://github.com/esl/MongooseIM
