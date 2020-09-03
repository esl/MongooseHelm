# MongooseIM in Kubernetes

This repository contains a [StatefulSet][sts] definition describing a simple yet
scalable and fault-tolerant MongooseIM cluster.

[sts]: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/

MongooseIM pods use the already existent MongooseIM container available
from DockerHub: https://hub.docker.com/r/mongooseim/mongooseim/
or GitHub: https://github.com/esl/MongooseIM.


## Getting started - initialize gcloud and kubectl

The following steps apply directly to [Google Kubernetes Engine][gke] (aka GKE),
but most Kubernetes environments should behave in a similar fashion.
If you're completely new to GKE you might be interested
in [GKE Quickstart](https://cloud.google.com/kubernetes-engine/docs/quickstart).

[gke]: https://cloud.google.com/kubernetes-engine/

Below is a recap of steps needed to setup our local machine to control
a Kubernetes cluster hosted on Google Cloud:

```sh
brew install google-cloud-sdk
gcloud init
```

At this point it might be convenient
to [set up `kubectl` shell autocompletion][kubectl-autocompletion].
This will enable easier discovery of all the useful subcommands,
so let's spend a while on setting it up and then get back to the rest of this tutorial.

[kubectl-autocompletion]: https://kubernetes.io/docs/tasks/tools/install-kubectl/#enabling-shell-autocompletion

Now let's create a cluster in Google Cloud web dashboard:
GCP -> Kubernetes Engine -> Create cluster. Then:

```sh
CLUSTER_NAME=standard-cluster-1  ## our actual cluster name
gcloud container clusters get-credentials $CLUSTER_NAME
```

Our `kubectl` is now configured to operate on the configured cluster.
Let's check that:

```sh
# Short info on what cluster we're operating on
kubectl config current-context
# Full info
kubectl config view
```

We're all set if the current context is something like:

```sh
$ kubectl config current-context
gke_praxis-magnet-229515_europe-west4-b_standard-cluster-1
```

Let's get the ball rolling!


## Deploy MongooseIM

When working with a Kubernetes cluster it's convenient to see the results
of taken actions. In order to do that, let's start a terminal window and run:

```sh
watch kubectl get node,pod,pv,pvc,sts,svc
```

This is going to be our monitoring window. We'll input commands in another terminal.

If you're reading this in your browser, it's time to clone the repo:

```sh
git clone https://github.com/esl/mongooseim-kubernetes
cd mongooseim-kubernetes
```

First, we have to store the configuration for MongooseIM pods into Kubernetes' etcd:

```sh
kubectl apply -f mongoose-cm.yaml
```

The config map will not be visible in the monitoring window,
since we're not monitoring this kind of resource.

MongooseIM pods will automatically initiate communication between one
another and form a cluster, but they require a DNS service for that.
We'll use a [Kubernetes headless service](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services)
and [StatefulSet stable network IDs](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-network-id)
to provide DNS for our cluster members:

```sh
kubectl apply -f mongoose-svc.yaml
```

Having enabled the service,
we should be able to see it appear in the monitoring window.

Let's deploy the cluster:

```sh
kubectl apply -f mongoose-sts.yaml
```

First, a `mongoose` StatefulSet should appear in the monitoring window,
followed by its pods. It will take a few minutes for all the
pods to start and become ready to serve traffic:

```
NAME             READY     STATUS    RESTARTS   AGE
pod/mongoose-0   1/1       Running   0          4m
pod/mongoose-1   1/1       Running   0          2m
pod/mongoose-2   1/1       Running   0          1m

NAME                        DESIRED   CURRENT   AGE
statefulset.apps/mongoose   3         3         4m
```

If a pod is stuck in `ContainerCreating` state, the first step should be:

```
kubectl describe pods
```

One reason for that might be forgetting to define the `mongoose-cm`
config map prior to starting the StatefulSet.

Once all the pods are up we can check the cluster status:

```
$ kubectl exec mongoose-0 /usr/lib/mongooseim/bin/mongooseimctl mnesia running_db_nodes
['mongooseim@mongoose-2.mongoose.default.svc.cluster.local',
 'mongooseim@mongoose-1.mongoose.default.svc.cluster.local',
 'mongooseim@mongoose-0.mongoose.default.svc.cluster.local']
```

The above command should return the same list of nodes (possibly in
different order) no matter whether we exec it on `mongoose-0`,
`mongoose-1`, or any other member of the cluster.


## Expose the XMPP service

There are two basic ways to expose the XMPP service to public internet.
The first and easiest is using a public IP provided by Google Cloud.
The second, somewhat more involved and less convenient, but at the same
time cheaper, is to use public IPs of Kubernetes worker nodes.


### Public XMPP IP with a load balancer

The most straightforward way to expose the service is via a load balancer
of the cloud provider:

```
kubectl apply -f mongoose-svc-lb.yaml
```

It will take up to a few minutes to get an IP address from the provider's
pool of public addresses, but once that's done, we should see it in the monitoring window:

```
NAME                  TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                                        AGE
service/kubernetes    ClusterIP      10.43.240.1    <none>          443/TCP                                        2h
service/mongoose      ClusterIP      None           <none>          4369/TCP,5222/TCP,5269/TCP,5280/TCP,9100/TCP   15m
service/mongoose-lb   LoadBalancer   10.43.247.53   35.204.210.47   5222:31810/TCP                                 1m
```

The service should now be reachable from any host with access to the
internet (including our local machines). A simple test would be running
telnet and pressing Ctrl-D to send the end of file symbol:

```
$ telnet 35.204.210.47 5222
Trying 35.204.210.47...
Connected to 47.210.204.35.bc.googleusercontent.com.
Escape character is '^]'.
<?xml version='1.0'?><stream:stream xmlns='jabber:client'...
```

Success! Since we're connecting with `telnet`, not an XMPP client, the
connection dies instantly, but we got the XMPP stream initiation element
from the server - the service is up, running, and reachable from everywhere.

In case we don't want to use this access method to the service we can tear
the load balancer down with:

```
kubectl delete svc mongoose-lb
```

### Direct access via external worker node IPs

The LoadBalancer is the more convenient, but also the more expensive
way of publishing a service.
We can also access our MongooseIM instances by using Kubernetes worker
nodes' external IP addresses.

In order to do that, we first have to create a NodePort service:

```
kubectl apply -f mongoose-svc-nodeport.yaml
```

After a while it should appear in our monitoring window:

```
NAME                        TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                                        AGE
service/kubernetes          ClusterIP   10.43.240.1    <none>        443/TCP                                        3h
service/mongoose            ClusterIP   None           <none>        4369/TCP,5222/TCP,5269/TCP,5280/TCP,9100/TCP   1h
service/mongoose-nodeport   NodePort    10.43.253.16   <none>        5222:32709/TCP                                 41s
```

The last line tells us that the service will be available on port 32709 of
Kubernetes workers' external interfaces.
We can find their external addresses (for example) with:

```
$ kubectl describe nodes | grep ExternalIP
  ExternalIP:  35.204.145.243
  ExternalIP:  35.204.114.176
  ExternalIP:  35.204.144.193
```

However, unlike with LoadBalancer, using NodePort we have to manually open
the relevant port (32709 in this case) in the firewall
(see [Creating a Service of type
NodePort](https://cloud.google.com/kubernetes-engine/docs/how-to/exposing-apps#creating_a_service_of_type_nodeport)
for the source of this command):

```sh
gcloud compute firewall-rules create mongoose-c2s-nodeport --allow tcp:32709
```

We can now check that the service is available from public internet (e.g.
our machine) in a similar fashion to testing the LoadBalancer setup
(run `telnet` and immediately type Ctrl-D):

```
$ telnet 35.204.114.176 32709
Trying 35.204.114.176...
Connected to 176.114.204.35.bc.googleusercontent.com.
Escape character is '^]'.
<?xml version='1.0'?><stream:stream xmlns='jabber:client'...
```

Again, the opening `<stream>` element means we've successfully connected
to our MongooseIM cluster.


## MongoosePush

The simplest way to run MPush is to run the following commands:

```
kubectl create -f mongoosepush-cm.yaml
kubectl apply -f mongoosepush.yaml
```

It will create the configmap being used by the service and expose the application's
8443 port, making it available to handle requests from inside the cluster.
At the time of writing this section, only FCM is supported, as MPush is started with APNS disabled.
To be able to communicate with k8s MPush instance from your localhost, you have to set up
the proxy to the pod with:

```
kubectl port-forward mongoosepush-<id> 8443
```

Now it will be accessable via e.g. `curl` on `localhost:8443` port.

## Watch out for the bills

If you're just trying things out
**remember to delete your cluster to avoid unnecessary costs**
after finishing the experiments.
Specifically, remember to delete all persistent volumes in the cloud
provider dashboard.
The persistent volumes are not deleted automatically anyway, so please remember to clean them up manually,
otherwise your next deployment will not succeed.


## Helm deployment

There is also a helm chart provided for both MongooseIM and MongoosePush services.
To have them up and running with only one command, run the following from the repo's main directory:

```
helm install your-chart-name mongoose-chart/
```

After a couple of minutes both services should be available. This command basically does what has
already been described in [Deploy MongooseIM](https://github.com/esl/mongooseim-kubernetes#deploy-mongooseim) chapter.
To uninstall the chart, simply run

```
helm uninstall your-chart-name
```


## Useful commands

There are some commands which might come in handy at times,
but do not have a very specific place in the tutorial above.

Run a "one off" command or start a shell in the cluster:

```
kubectl run busybee -it --rm --restart=Never --image=busybox [-- optional-command-goes-here]
```

Run the following command to list available k8s clusters:

```
kubectl config get-contexts
```

Switching the context can be done using `NAME` from the above listing.
Specifically, it might be useful to switch from operating a cloud-hosted
cluster to a local one:

```
kubectl config use-context CONTEXT-NAME
kubectl config use-context docker-desktop  # if Docker Desktop with Kubernetes is enabled
```
