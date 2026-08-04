#!/bin/bash
# SSM Agent 설치 및 시작 (minimal AMI엔 기본 미포함)
sudo dnf install -y amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

sudo -u ec2-user mkdir -p /home/ec2-user/bin

sudo curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.3/2026-04-08/bin/linux/amd64/kubectl
sudo mv /kubectl /home/ec2-user/bin/kubectl
sudo chown ec2-user:ec2-user /home/ec2-user/bin/kubectl
sudo chmod +x /home/ec2-user/bin/kubectl

sudo -u ec2-user aws eks update-kubeconfig --region ${region} --name ${cluster_name}