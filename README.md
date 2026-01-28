# Mongoose stack in Kubernetes

This repository contains a [StatefulSet][sts] definition describing a simple yet scalable and fault-tolerant MongooseIM cluster.

MongooseIM pods use the already existing MongooseIM container available from [MongooseIM's DockerHub][MIM-docker] or [GitHub][MIM]. Likewise, MongoosePush uses the containers available from [Mongoose Push' dockerhub][MPush-docker]. You can read more about them in their respective READMEs, for [MongooseIM](./MongooseIM/README.md) and [MongoosePush](./MongoosePush/README.md)

  * [Add this repo to your local helm](#add-this-repo-to-your-local-helm)
  * [Initialise a K8S cluster](#initialise-a-k8s-cluster)
  * [How to get the plain k8s files](#how-to-get-the-plain-k8s-files)

## Add this repo to your local helm

Running the following command:

```sh
helm repo add mongoose https://esl.github.io/MongooseHelm/
```

Will add this repo to your local helm charts, so you can install any of the available packages in your kubernetes cluster.

## Initialise a k8s cluster

The most important part about managing a k8s cluster, is to actually have one! Many solutions are available, like [minikube], [microk8s], or [Docker Desktop] for local deployments, most often development and experimentation; or services like [Google Kubernetes Engine][GKE], [Azure Kubernetes Service][AKS], or [Amazon Elastic Container Service][AEKS]. Refer to their documentation to know how to set them up.

[minikube]: https://minikube.sigs.k8s.io/docs/
[microk8s]: https://microk8s.io/
[Docker Desktop]: https://docs.docker.com/docker-for-mac/kubernetes/
[GKE]: https://cloud.google.com/kubernetes-engine/
[AKS]: https://azure.microsoft.com/en-us/services/kubernetes-service/
[AEKS]: https://aws.amazon.com/eks/

Any of these should make our `kubectl` is now configured to operate on the configured cluster. Let's check that:

```sh
kubectl config current-context  # Short info on what cluster we're operating on
kubectl config get-contexts     # See all available contexts
kubectl config view             # Full config info
```

Switching the context can be done using `NAME` from the above listing. Specifically, it might be useful to switch from operating a cloud-hosted cluster to a local one:

```
kubectl config use-context CONTEXT-NAME
kubectl config use-context docker-desktop  # if using Docker Desktop with Kubernetes, or
kubectl config use-context minikube  # if using minikube as the k8s cluster
```

## How to get the plain k8s files

If all you want is the plain k8s files, you can tell helm to expand the templates for you using the command

```sh
helm template desired-chart --output-dir desired-path
```

Where `desired-chart` is the desired chart to obtain (MongooseIM or MongoosePush) and `desired-path` is the path where you want to output the k8s yaml definitions.

[MIM]: https://github.com/esl/MongooseIM
[MIM-docker]: https://hub.docker.com/r/erlangsolutions/mongooseim/
[MPush-docker]: https://hub.docker.com/r/erlangsolutions/mongoose-push
[sts]: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
