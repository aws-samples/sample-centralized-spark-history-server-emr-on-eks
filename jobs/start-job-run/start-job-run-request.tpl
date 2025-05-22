{
  "name": "${SPARK_JOB_NAME}", 
  "virtualClusterId": "${VIRTUAL_CLUSTER_ID}",  
  "executionRoleArn": "${IAM_ROLE_ARN_FOR_JOB_EXECUTION}",
  "releaseLabel": "emr-7.2.0-latest", 
  "jobDriver": {
    "sparkSubmitJobDriver": {
      "entryPoint": "",
      "entryPointArguments": [
        "--input-path",
        "s3://${S3_BUCKET_NAME}/data/input",
        "--output-path",
        "s3://${S3_BUCKET_NAME}/data/output"
      ],
       "sparkSubmitParameters": "--conf spark.driver.cores=1 --conf spark.driver.memory=4G --conf spark.kubernetes.driver.limit.cores=1200m --conf spark.executor.cores=2  --conf spark.executor.instances=3  --conf spark.executor.memory=4G"
    }
  }, 
  "configurationOverrides": {
    "applicationConfiguration": [
      {
        "classification": "spark-defaults", 
        "properties": {
          "spark.driver.memory":"2G",
          "spark.kubernetes.container.image": "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${EMR_REPO_NAME}:${EMR_IMAGE_TAG}",
          "spark.app.name": "${SPARK_JOB_NAME}",
          "spark.eventLog.enabled": "true",
          "spark.eventLog.dir": "s3://${S3_BUCKET_NAME}/spark-events/"
         }
      }
    ], 
    "monitoringConfiguration": {
      "persistentAppUI": "ENABLED",
      "s3MonitoringConfiguration": {
        "logUri": "s3://${S3_BUCKET_NAME}/spark-events/"
      }
    }
  }
}