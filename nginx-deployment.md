# Nginx Deployment on Multiple Architectures

This document provides the necessary Kubernetes manifests and instructions to deploy nginx on both arm64 and amd64 nodes using Karpenter for node provisioning.

## Requirements

- Single deployment with pods on both arm64 and amd64 architectures
- Latest nginx version
- 2 replicas per architecture (4 total)
- LoadBalancer service for external access

## Deployment Manifest

Create a file named `nginx-deployment.yaml` with the following content:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 4
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      # Ensure pods are spread across different architectures
      topologySpreadConstraints:
      - maxSkew: 1  # Allow some skew for flexibility during provisioning
        topologyKey: kubernetes.io/arch
        whenUnsatisfiable: DoNotSchedule  # This forces Karpenter to provision nodes of both architectures
        labelSelector:
          matchLabels:
            app: nginx
      affinity:
        # This ensures Karpenter provisions the right nodes if they don't exist
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values:
                - amd64
            - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values:
                - arm64
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
```

## Service Manifest

Create a file named `nginx-service.yaml` with the following content:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: nginx
```

## ConfigMap Manifest

Create a file named `nginx-config.yaml` with the following content:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  nginx.conf: |
    server {
        listen 80;
        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
            add_header X-Node-Architecture $hostname;
        }
    }
```

This ConfigMap contains a custom nginx configuration that adds the `X-Node-Architecture` header to responses, which includes the pod's hostname. This allows us to verify that requests are being served by pods on different architecture nodes.

## Deployment Instructions

> **IMPORTANT**: The order of applying resources is critical. Always apply the ConfigMap first, then the Deployment, and finally the Service.

1. Apply the ConfigMap first:
   ```bash
   kubectl apply -f nginx-config.yaml
   ```
   This ensures the ConfigMap exists before the pods try to mount it.

2. Apply the deployment manifest:
   ```bash
   kubectl apply -f nginx-deployment.yaml
   ```

3. Apply the service manifest:
   ```bash
   kubectl apply -f nginx-service.yaml
   ```

Alternatively, you can apply all resources in a single command, and kubectl will handle the dependency order:
```bash
kubectl apply -f nginx-config.yaml -f nginx-deployment.yaml -f nginx-service.yaml
```

If you find that Karpenter doesn't automatically provision ARM64 nodes (all pods are on AMD64 nodes or some are stuck in Pending state), you can use the fallback option:
```bash
kubectl apply -f arm64-test-pod.yaml
```
This will force Karpenter to provision an ARM64 node. See the "Forcing ARM64 Node Provisioning" section for more details.

3. Monitor the pod creation process:
   ```bash
   kubectl get pods -l app=nginx -w
   ```
   This will show real-time updates as pods are created and their status changes.

4. Verify the deployment:
   ```bash
   kubectl get pods -l app=nginx -o wide
   ```
   This should show 4 nginx pods distributed across arm64 and amd64 nodes.

5. Check if Karpenter has provisioned the necessary nodes:
   ```bash
   kubectl get nodes -L kubernetes.io/arch
   ```
   You should see both AMD64 and ARM64 nodes in the list.

5. Get the LoadBalancer endpoint:
   ```bash
   kubectl get service nginx
   ```
   The EXTERNAL-IP column will show the LoadBalancer endpoint.

6. Monitor the architecture distribution:
   ```bash
   kubectl get pods -l app=nginx -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,ARCH:.spec.nodeSelector.kubernetes\\.io/arch
   ```

7. Check which nodes Karpenter has provisioned:
   ```bash
   kubectl get nodes -L kubernetes.io/arch,karpenter.sh/provisioned-by
   ```

## Explanation

### Architecture Distribution

The deployment uses `topologySpreadConstraints` with `maxSkew: 1` and `whenUnsatisfiable: DoNotSchedule` to enforce an even distribution of pods across different architectures. With `DoNotSchedule`, pods will not be scheduled if they would violate the topology spread constraints, which forces Karpenter to provision nodes of both architectures. The goal is to have 2 pods running on arm64 nodes and 2 pods running on amd64 nodes.

> **Note**: The original example used `whenUnsatisfiable: ScheduleAnyway`, which only encourages distribution but doesn't enforce it. We found that with `ScheduleAnyway`, all pods would be scheduled on AMD64 nodes if they were already available, and Karpenter wouldn't provision ARM64 nodes. Changing to `DoNotSchedule` forces Karpenter to provision ARM64 nodes to satisfy the constraints.

### Node Provisioning

If there aren't enough nodes of a particular architecture, Karpenter will automatically provision them based on the NodePool configuration. The NodePool is already configured to support both arm64 and amd64 architectures:

```yaml
requirements:
  - key: "kubernetes.io/arch"
    operator: In
    values: ["amd64", "arm64"]
```

### Node Affinity

The deployment uses node affinity to ensure that pods are scheduled on nodes with the correct architecture. This is important for Karpenter to know which type of nodes to provision.

### LoadBalancer Service

The LoadBalancer service exposes the nginx deployment externally. In AWS, this will create an ELB that routes traffic to the nginx pods.

## Troubleshooting

### Forcing ARM64 Node Provisioning (Fallback Option)

In theory, with `whenUnsatisfiable: DoNotSchedule` in the topology spread constraints, Karpenter should automatically provision ARM64 nodes to satisfy the constraints. However, in some cases, you might need a fallback option.

The `arm64-test-pod.yaml` file serves as a troubleshooting tool that explicitly forces Karpenter to provision an ARM64 node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: arm64-test
  labels:
    app: arm64-test
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
  containers:
  - name: nginx
    image: nginx:latest
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

You might need this fallback option if:
1. There's an issue with how the topology spread constraints are interpreted
2. There's a race condition where all pods get scheduled on AMD64 nodes before Karpenter can provision ARM64 nodes
3. There are other constraints that take precedence over the topology spread constraints

Save this as `arm64-test-pod.yaml` and apply it only if you find that all nginx pods are scheduled on AMD64 nodes or some are stuck in Pending state:
```bash
kubectl apply -f arm64-test-pod.yaml
```

This will guarantee that Karpenter provisions an ARM64 node, which should then allow the nginx pods to be properly distributed across both architectures.

### Pods Stuck in Pending State

If pods are stuck in the Pending state, it might be because:

1. **ConfigMap not found**: If you applied the deployment before the ConfigMap, pods will be stuck with a "ConfigMap not found" error. Check pod events:
   ```bash
   kubectl describe pods -l app=nginx
   ```
   If you see `MountVolume.SetUp failed for volume "nginx-config" : configmap "nginx-config" not found`, apply the ConfigMap and delete the pods to trigger recreation:
   ```bash
   kubectl apply -f nginx-config.yaml
   kubectl delete pods -l app=nginx
   ```

2. **Karpenter is still provisioning nodes**: Check Karpenter logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter
   ```
   Provisioning new nodes can take 3-5 minutes.

3. **Node provisioning failed**: Look for errors in the Karpenter logs related to EC2 instance provisioning.

4. **Insufficient quota**: You might have reached your EC2 instance quota. Check the AWS console or run:
   ```bash
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
   ```

### Pods Not Evenly Distributed

If pods are not evenly distributed across architectures:

1. **Check node availability**: Ensure that nodes of both architectures are available:
   ```bash
   kubectl get nodes -L kubernetes.io/arch
   ```

2. **Adjust topology spread constraints**: You might need to adjust the `maxSkew` value in the deployment.

3. **Force redistribution**: Delete some pods to trigger rescheduling:
   ```bash
   kubectl delete pod -l app=nginx --field-selector spec.nodeName=<node-name>
   ```

### LoadBalancer Not Provisioned

If the LoadBalancer service doesn't get an external IP:

1. **Check service status**:
   ```bash
   kubectl describe service nginx
   ```

2. **Verify AWS permissions**: Ensure that the cluster has permissions to create load balancers.

3. **Check AWS load balancer controller**: If you're using the AWS Load Balancer Controller, check its logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```

## Testing the Deployment

Once the deployment is up and running, you can test it to ensure it's working correctly:

### 1. Verify Pod Distribution

Check that pods are running on both arm64 and amd64 nodes:

```bash
kubectl get pods -l app=nginx -o wide
```

Look at the NODE column and verify that pods are distributed across different nodes. Then check the architecture of those nodes:

```bash
kubectl get nodes -L kubernetes.io/arch | grep <node-name>
```

### 2. Test the LoadBalancer

Get the LoadBalancer endpoint:

```bash
kubectl get service nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Use curl to test the endpoint:

```bash
curl -v http://<loadbalancer-endpoint>
```

You should see the nginx welcome page.

### 3. Verify Multi-Architecture Serving

To verify that requests are being served by both arm64 and amd64 pods, we use the custom header in our nginx configuration that includes the pod's hostname.

Then test with multiple requests to see different architecture headers:

```bash
# Store the LoadBalancer endpoint in a variable
export NGINX_IP=$(kubectl get service nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test multiple requests to see responses from different nodes
for i in {1..10}; do curl -s -I http://$NGINX_IP | grep X-Node-Architecture; done
```

You should see responses from pods on both AMD64 and ARM64 nodes, confirming that traffic is being distributed across architectures:

```
X-Node-Architecture: nginx-6cfcd4dcff-2pms5  # Pod on AMD64 node
X-Node-Architecture: nginx-6cfcd4dcff-nrdpd  # Pod on ARM64 node
X-Node-Architecture: nginx-6cfcd4dcff-wjmqj  # Pod on ARM64 node
X-Node-Architecture: nginx-6cfcd4dcff-x49q5  # Pod on AMD64 node
```

## Conclusion

This deployment demonstrates how to effectively use Karpenter to provision nodes of different architectures (arm64 and amd64) and deploy a single application across them. By using topology spread constraints with `whenUnsatisfiable: DoNotSchedule`, we enforce an even distribution of pods across architectures, which provides several benefits:

1. **Cost Optimization**: ARM instances are typically cheaper than their x86 counterparts, so using a mix can reduce costs.
2. **Performance Testing**: You can compare the performance of your application on different architectures.
3. **Resilience**: If there's an issue with one architecture, your application can still run on the other.
4. **Flexibility**: As cloud providers expand their ARM offerings, you're already set up to take advantage of them.

The key components that make this work are:

1. **Karpenter NodePool** with support for both architectures
2. **Topology Spread Constraints** to distribute pods across architectures
3. **Node Affinity** to ensure pods can run on either architecture
4. **LoadBalancer Service** to provide a single entry point regardless of the underlying node architecture

This approach can be extended to other applications and use cases where multi-architecture deployments are beneficial.

## Key Lessons Learned

1. **Order of resource application matters**: Always apply ConfigMaps before Deployments that use them to avoid "ConfigMap not found" errors.

2. **Topology spread constraints behavior**: Using `whenUnsatisfiable: ScheduleAnyway` only encourages distribution but doesn't enforce it. For guaranteed multi-architecture deployment, use `whenUnsatisfiable: DoNotSchedule`.

3. **Fallback for architecture-specific nodes**: While topology spread constraints with `DoNotSchedule` should theoretically force Karpenter to provision nodes of both architectures, having a fallback option (arm64-test-pod.yaml) is valuable for troubleshooting and ensuring ARM64 nodes are provisioned if needed.

4. **Verification is important**: Always verify that your pods are running on the expected node architectures and that traffic is being distributed across them.