{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:CreateLoadBalancer",
              "elasticloadbalancing:CreateTargetGroup"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*"
          ],
          "Condition": {
              "Null": {
                  "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:CreateListener",
              "elasticloadbalancing:DeleteListener",
              "elasticloadbalancing:CreateRule",
              "elasticloadbalancing:DeleteRule"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener-rule/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*/*"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:AddTags",
              "elasticloadbalancing:RemoveTags"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/net/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/app/*/*"
          ],
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
              "elasticloadbalancing:AddTags",
              "elasticloadbalancing:RemoveTags"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener/net/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener/app/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener-rule/net/*/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener-rule/app/*/*/*"
          ]
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:ModifyLoadBalancerAttributes",
              "elasticloadbalancing:SetIpAddressType",
              "elasticloadbalancing:SetSecurityGroups",
              "elasticloadbalancing:SetSubnets",
              "elasticloadbalancing:DeleteLoadBalancer",
              "elasticloadbalancing:ModifyTargetGroup",
              "elasticloadbalancing:ModifyTargetGroupAttributes",
              "elasticloadbalancing:DeleteTargetGroup",
              "elasticloadbalancing:ModifyListenerAttributes",
              "elasticloadbalancing:ModifyCapacityReservation"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*/*"
          ],
          "Condition": {
              "Null": {
                  "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:AddTags"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/net/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/app/*/*"
          ],
          "Condition": {
              "StringEquals": {
                  "elasticloadbalancing:CreateAction": [
                      "CreateTargetGroup",
                      "CreateLoadBalancer"
                  ]
              },
              "Null": {
                  "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
              }
          }
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:RegisterTargets",
              "elasticloadbalancing:DeregisterTargets"
          ],
          "Resource": "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:targetgroup/*/*"
      },
      {
          "Effect": "Allow",
          "Action": [
              "elasticloadbalancing:SetWebAcl",
              "elasticloadbalancing:ModifyListener",
              "elasticloadbalancing:AddListenerCertificates",
              "elasticloadbalancing:RemoveListenerCertificates",
              "elasticloadbalancing:ModifyRule"
          ],
          "Resource": [
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:loadbalancer/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener/*/*",
              "arn:aws:elasticloadbalancing:${AWS_REGION}:${AWS_ACCOUNT_ID}:listener-rule/*/*"
          ]
      }
  ]
}