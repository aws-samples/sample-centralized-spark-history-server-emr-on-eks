# _helpers.tpl

{{/*
Expand the name of the chart.
*/}}
{{- define "spark.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "spark.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "spark.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "spark.labels" -}}
helm.sh/chart: {{ include "spark.chart" . }}
{{ include "spark.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: spark-history-server
{{- end }}

{{/*
Selector labels
*/}}
{{- define "spark.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spark.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "spark.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "spark.name" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Define init container for S3 logs folder
*/}}
{{- define "spark.initContainer" -}}
- name: s3-logs-folder
  image: "{{ .Values.create_s3_logs_folder.image.repository }}:{{ .Values.create_s3_logs_folder.image.tag }}"
  imagePullPolicy: {{ .Values.create_s3_logs_folder.image.pull_policy }}
  command:
    - /bin/bash
    - -c
    - |
      export HOME=/opt/spark/logs
      # Create the logs prefix if it doesn't exist
      # Using head-object to check if prefix exists, suppress error output
      if ! aws s3api head-object --bucket {{ .Values.s3.bucket.name }} --key spark-events/ 2>/dev/null; then
          aws s3api put-object --bucket {{ .Values.s3.bucket.name }} --key spark-events/
      fi

      # Create and upload initial log file
      # Only upload if it doesn't already exist in S3
      touch /opt/spark/logs/initial.log
      if ! aws s3 ls s3://{{ .Values.s3.bucket.name }}/spark-events/initial.log 2>/dev/null; then
          aws s3 cp /opt/spark/logs/initial.log s3://{{ .Values.s3.bucket.name }}/spark-events/
      fi
  resources: 
    {{- toYaml .Values.create_s3_logs_folder.resources | nindent 4 }}
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    runAsUser: 1000
  env:
    - name: AWS_CONFIG_FILE
      value: /opt/spark/logs/.aws/config
    - name: AWS_SHARED_CREDENTIALS_FILE
      value: /opt/spark/logs/.aws/credentials
  volumeMounts:
    - name: opt-spark-logs
      mountPath: /opt/spark/logs/
{{- end }}