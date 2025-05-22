apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: spark-history-server-demo-${CLUSTER_NAME}
  namespace: emr
  labels:
    cluster: ${CLUSTER_NAME}
spec:

  type: Python
  mode: cluster
  image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${EMR_REPO_NAME}:${EMR_IMAGE_TAG}
  imagePullPolicy: Always
  mainApplicationFile: s3://${S3_BUCKET_NAME}/app/${SPARK_APP_FILE}
  arguments:
    - "--input-path"
    - "s3://${S3_BUCKET_NAME}/data/input"
    - "--output-path"
    - "s3://${S3_BUCKET_NAME}/data/output"
  sparkVersion: 3.3.1
  restartPolicy:
    type: Never

  sparkConf:
    "spark.app.name": "spark-operator-demo-${CLUSTER_NAME}"
    "spark.eventLog.enabled": "true"
    "spark.eventLog.dir": "s3://${S3_BUCKET_NAME}/spark-events"
    "spark.history.fs.logDirectory": "s3://${S3_BUCKET_NAME}/spark-events"
  
  hadoopConf:
    "fs.s3a.aws.credentials.provider": "com.amazonaws.auth.WebIdentityTokenCredentialsProvider"

  driver:
    cores: 1
    coreLimit: 1200m
    memory: 4G
    labels:
      version: 3.3.1
    serviceAccount: emr-containers-sa-spark

  executor:
    cores: 2
    instances: 3
    memory: 4G
    labels:
      version: 3.3.1
    serviceAccount: emr-containers-sa-spark
  

  
