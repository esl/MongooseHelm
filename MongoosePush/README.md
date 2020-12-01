## MongoosePush

MongoosePush is a simple Elixir RESTful service allowing to send push notification via FCM and/or APNS.

The simplest way to run MPush is to run the following commands:

```sh
helm repo add mongoose https://esl.github.io/MongooseHelm/
helm install my-mongoosepush mongoose/mongoosepush
```

It will create the configmap being used by the service and expose the application's
8443 port, making it available to handle requests from inside the cluster.
At the time of writing this section, only FCM is supported, as MPush is started with APNS disabled.
To be able to communicate with k8s MPush instance from your localhost, you have to set up
the proxy to the pod with:

```sh
kubectl port-forward mongoosepush-<id> 8443
```

Now it will be accessible via e.g. `curl` on `localhost:8443` port.
