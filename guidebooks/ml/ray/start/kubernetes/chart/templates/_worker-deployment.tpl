{{- define "worker-deployment" -}}

apiVersion: v1
kind: ConfigMap
metadata:
  name: path-to-inputfile
data:
  inputfile.txt: |
    gto/aws.json

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ray.workers" . }}
  namespace: {{ .Values.clusterNamespace }}
spec:
  # Change this to scale the number of worker nodes started in the Ray cluster.
  replicas: {{ .Values.podTypes.rayWorkerType.maxWorkers | default 1 }}
  selector:
    matchLabels:
      component: ray-worker
      type: ray
  template:
    metadata:
      labels:
        identity_template: "true"
        component: ray-worker
        type: ray
        appwrapper.mcad.ibm.com: {{ .Values.clusterName }}
        ray-node-type: worker
        ray-cluster-name: {{ .Values.clusterName }}
        ray-user-node-type: rayWorkerType
        ray-node-name: {{ include "ray.workers" . }}

        {{ if eq .Values.mcad.scheduler "coscheduler" }}
        pod-group.scheduling.sigs.k8s.io: {{ include "ray.podgroup" . }}
        {{ end }}

    spec:
      {{ if eq .Values.mcad.scheduler "coscheduler" }}
      schedulerName: scheduler-plugins-scheduler
      {{ end }}

      restartPolicy: Always
      volumes:
      - name: mount-inputfile
        configMap:
          name: path-to-inputfile
      - name: spire-agent-socket
        hostPath:
          path: /run/spire/sockets
          type: Directory
      - name: db-config
        emptyDir: {}
      - name: dshm
        emptyDir:
          medium: Memory
      {{- if .Values.pvcs }}
      {{- if .Values.pvcs.rayWorkerType }}
      {{- range $key, $val := .Values.pvcs.rayWorkerType }}
      - name: {{ regexReplaceAll "\\." $val.claim "-" }}
        persistentVolumeClaim:
          claimName: {{ $val.claim }}
      {{- end }}
      {{- end }}
      {{- end }}
      containers:
      - name: apps-sidecar
        # image: us.gcr.io/scytale-registry/aws-cli:latest
        image: tsidentity/tornjak-example-sidecar:v0.1
        imagePullPolicy: Always
        # command: ["sleep"]
        #args: ["1000000000"]
        command: ["/usr/local/bin/run-sidecar-bash.sh"]
        args:
          - "/usr/local/bin/inputfile.txt"
        env:
        - name: SOCKETFILE
          value: "/run/spire/sockets/agent.sock"
        - name: ROLE
          value: "gtorole"
        - name: VAULT_ADDR
          # Provide address to your VAULT server
          value: "http://tsi-vault-tsi-vault.gto-demo-02-9d995c4a8c7c5f281ce13d5467ff6a94-0000.us-east.containers.appdomain.cloud"
        # make openshift local happy
        securityContext:
          # runAsNonRoot: true
          # allowPrivilegeEscalation: false
          # privileged is needed to create socket and bundle files
          privileged: true
        volumeMounts:
          # access to SPIRE Agent:
          - name: spire-agent-socket
            mountPath: /run/spire/sockets
            readOnly: true
          - name: db-config
            mountPath: /run/db
          - name: mount-inputfile
            mountPath: /usr/local/bin/inputfile.txt
            subPath: inputfile.txt

      - name: ray-worker
        image: {{ .Values.image }}
        imagePullPolicy: IfNotPresent
        command: ["/bin/bash", "-c", "--"]
        args:
          - {{ print "ray start --num-cpus=" .Values.podTypes.rayWorkerType.CPUInteger " --num-gpus=" .Values.podTypes.rayWorkerType.GPU " --address=" (include "ray.headService" .) ":6379 --object-manager-port=22345 --node-manager-port=22346 --block" }}

        # This volume allocates shared memory for Ray to use for its plasma
        # object store. If you do not provide this, Ray will fall back to
        # /tmp which cause slowdowns if is not a shared memory volume.
        volumeMounts:
          - mountPath: /home/aws
            name: db-config
            readOnly: true
          - mountPath: /dev/shm
            name: dshm
        {{- if .Values.pvcs }}
        {{- if .Values.pvcs.rayWorkerType }}
        {{- range $key, $val := .Values.pvcs.rayWorkerType }}
          - name: {{ regexReplaceAll "\\." $val.claim "-" }}
            mountPath: {{ $val.mountPath }}
        {{- end }}
        {{- end }}
        {{- end }}
        env:
        resources:
          requests:
            cpu: {{ .Values.podTypes.rayWorkerType.CPU }}
            memory: {{ .Values.podTypes.rayWorkerType.memory }}
          limits:
            cpu: {{ .Values.podTypes.rayWorkerType.CPU }}
            # The maximum memory that this pod is allowed to use. The
            # limit will be detected by ray and split to use 10% for
            # redis, 30% for the shared memory object store, and the
            # rest for application memory. If this limit is not set and
            # the object store size is not set manually, ray will
            # allocate a very large object store in each pod that may
            # cause problems for other pods.
            memory: {{ .Values.podTypes.rayWorkerType.memory }}
            {{- if .Values.podTypes.rayWorkerType.GPU }}
            nvidia.com/gpu: {{ .Values.podTypes.rayWorkerType.GPU }}
            {{- end }}
{{end}}
