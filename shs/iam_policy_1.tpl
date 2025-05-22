{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "iam:CreateServiceLinkedRole"
          ],
          "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/aws-service-role/elasticloadbalancing.amazonaws.com/*",
          "Condition": {
              "StringEquals": {
                  "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:DescribeAccountAttributes",
              "ec2:DescribeAddresses",
              "ec2:DescribeAvailabilityZones",
              "ec2:DescribeInternetGateways",
              "ec2:DescribeVpcs",
              "ec2:DescribeVpcPeeringConnections",
              "ec2:DescribeSubnets",
              "ec2:DescribeSecurityGroups",
              "ec2:DescribeInstances",
              "ec2:DescribeNetworkInterfaces",
              "ec2:DescribeTags",
              "ec2:GetCoipPoolUsage",
              "ec2:DescribeCoipPools",
              "ec2:GetSecurityGroupsForVpc",
              "elasticloadbalancing:DescribeLoadBalancers",
              "elasticloadbalancing:DescribeLoadBalancerAttributes",
              "elasticloadbalancing:DescribeListeners",
              "elasticloadbalancing:DescribeListenerCertificates",
              "elasticloadbalancing:DescribeSSLPolicies",
              "elasticloadbalancing:DescribeRules",
              "elasticloadbalancing:DescribeTargetGroups",
              "elasticloadbalancing:DescribeTargetGroupAttributes",
              "elasticloadbalancing:DescribeTargetHealth",
              "elasticloadbalancing:DescribeTags",
              "elasticloadbalancing:DescribeTrustStores",
              "elasticloadbalancing:DescribeListenerAttributes",
              "elasticloadbalancing:DescribeCapacityReservation"
          ],
          "Resource": "*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "cognito-idp:DescribeUserPoolClient"
          ],
          "Resource": "arn:aws:cognito-idp:${AWS_REGION}:${AWS_ACCOUNT_ID}:userpool/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "acm:ListCertificates",
              "acm:DescribeCertificate"
          ],
          "Resource": "arn:aws:acm:${AWS_REGION}:${AWS_ACCOUNT_ID}:certificate/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "iam:ListServerCertificates",
              "iam:GetServerCertificate"
          ],
          "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:server-certificate/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "waf-regional:GetWebACL",
              "waf-regional:GetWebACLForResource",
              "waf-regional:AssociateWebACL",
              "waf-regional:DisassociateWebACL"
          ],
          "Resource": [
              "arn:aws:waf-regional:${AWS_REGION}:${AWS_ACCOUNT_ID}:webacl/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "wafv2:GetWebACL",
              "wafv2:GetWebACLForResource",
              "wafv2:AssociateWebACL",
              "wafv2:DisassociateWebACL"
          ],
          "Resource": [
              "arn:aws:wafv2:${AWS_REGION}:${AWS_ACCOUNT_ID}:*/webacl/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "shield:GetSubscriptionState",
              "shield:DescribeProtection",
              "shield:CreateProtection",
              "shield:DeleteProtection"
          ],
          "Resource": "arn:aws:shield::${AWS_ACCOUNT_ID}:protection/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:AuthorizeSecurityGroupIngress",
              "ec2:RevokeSecurityGroupIngress"
          ],
          "Resource": "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:security-group/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:CreateSecurityGroup"
          ],
          "Resource": [
              "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:security-group/*",
              "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:vpc/*"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:CreateTags"
          ],
          "Resource": "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:security-group/*",
          "Condition": {
              "StringEquals": {
                  "ec2:CreateAction": "CreateSecurityGroup"
              },
              "Null": {
                  "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:CreateTags",
              "ec2:DeleteTags"
          ],
          "Resource": "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:security-group/*",
          "Condition": {
              "Null": {
                  "aws:RequestTag/elbv2.k8s.aws/cluster": "true",
                  "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "ec2:AuthorizeSecurityGroupIngress",
              "ec2:RevokeSecurityGroupIngress",
              "ec2:DeleteSecurityGroup"
          ],
          "Resource": "arn:aws:ec2:${AWS_REGION}:${AWS_ACCOUNT_ID}:security-group/*",
          "Condition": {
              "Null": {
                  "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      }
  ]
}