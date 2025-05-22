service_account_name: spark-history-server-sa
# -- Service Account configuration
serviceAccount:
  create: false
  name: spark-history-server-sa
  annotations: {}

image:
  repository: public.ecr.aws/g0x0x5e1/spark-history-server/emr-x.xx.x
  pull_policy: Always
  tag: latest

s3:
  bucket:
    name: spark-logs-bucket-3442
    prefix: /spark-events

ingress:
  enabled: true
  className: "alb"
  annotations:
    kubernetes.io/ingress.class: "alb"
    alb.ingress.kubernetes.io/scheme: "internal"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/subnets: subnet-xxxx,subnet-xxxx
    alb.ingress.kubernetes.io/load-balancer-name: "spark-history-server"
    alb.ingress.kubernetes.io/target-group-attributes: "deregistration_delay.timeout_seconds=30"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:xxxxxxx:xxxxxxxxx:certificate/xxxxxxxxxxx
    alb.ingress.kubernetes.io/healthcheck-path: "/"
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "15"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "5"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "2"
    alb.ingress.kubernetes.io/success-codes: "200-399"
  tls:
    - hosts:
        - "shs.example.internal"