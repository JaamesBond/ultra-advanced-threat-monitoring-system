#--------------------------------------------------------------
# XDR Inline Inspection Appliance (EC2)
#
# Dedicated instance for Zeek + Suricata network sensors.
# Sits in the inspection path: TGW → inspection subnet → NAT GW.
#
# No EKS in XDR VPC. Security pipeline runs in bc-ctrl + bc-prd.
#
# Access: SSM Session Manager only (no SSH key, no public IP)
# Zeek + Vector (CloudWatch) deployed via Docker in user_data.
#--------------------------------------------------------------

data "aws_ami" "ubuntu_xdr" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#--------------------------------------------------------------
# IAM — SSM access
#--------------------------------------------------------------

resource "aws_iam_role" "xdr_test" {
  name = "bc-xdr-test-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "xdr_test_ssm" {
  role       = aws_iam_role.xdr_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "xdr_test_zeek_logs" {
  name = "bc-xdr-test-zeek-cloudwatch"
  role = aws_iam_role.xdr_test.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Resource = "arn:aws:logs:${local.region}:*:log-group:/bc-xdr/zeek:*"
    }]
  })
}

resource "aws_iam_instance_profile" "xdr_test" {
  name = "bc-xdr-test-profile"
  role = aws_iam_role.xdr_test.name
}

#--------------------------------------------------------------
# Security Group — intra-VPC + TGW inbound, egress all
#--------------------------------------------------------------

resource "aws_security_group" "xdr_test" {
  name        = "bc-xdr-test-sg"
  description = "XDR infrastructure test instance - SSM only, no public ingress"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "All traffic from within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "Traffic from Control Plane VPC via TGW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.ctrl_vpc_cidr]
  }

  ingress {
    description = "Traffic from Production spoke via TGW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.prd_vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "bc-xdr-test-sg" })
}

#--------------------------------------------------------------
# EC2 Instance — t3.medium, Ubuntu 24.04, private subnet
#--------------------------------------------------------------

resource "aws_instance" "xdr_test" {
  ami                    = data.aws_ami.ubuntu_xdr.id
  instance_type          = "t3.medium"
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.xdr_test.id]
  iam_instance_profile   = aws_iam_instance_profile.xdr_test.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y ca-certificates curl git

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    usermod -aG docker ubuntu

    # ── Zeek: network security monitor ──────────────────────────
    mkdir -p /opt/zeek/{logs,config,spool}

    # Zeek local.zeek config — enable standard scripts + JSON logging
    cat > /opt/zeek/config/local.zeek <<'ZEEKCONF'
    @load base/protocols/conn
    @load base/protocols/dns
    @load base/protocols/http
    @load base/protocols/ssl
    @load frameworks/files/hash-all-files
    @load policy/frameworks/notice/community-id
    @load policy/protocols/ssl/validate-certs
    @load policy/tuning/json-logs
    redef LogAscii::use_json = T;
    ZEEKCONF

    # Detect primary interface
    PRIMARY_IF=$(ip -o link show up | awk -F': ' '!/lo/{print $2; exit}')

    docker run -d \
      --name zeek \
      --restart always \
      --net=host \
      --cap-add=NET_RAW \
      --cap-add=NET_ADMIN \
      --workdir /zeek/logs \
      -v /opt/zeek/logs:/zeek/logs \
      -v /opt/zeek/config/local.zeek:/usr/local/zeek/share/zeek/site/local.zeek:ro \
      zeek/zeek:latest \
      zeek -i "$PRIMARY_IF" local

    # ── Vector: ship Zeek logs to CloudWatch ────────────────────
    mkdir -p /opt/vector

    cat > /opt/vector/vector.yaml <<'VECTORCONF'
    sources:
      zeek_logs:
        type: file
        include:
          - /zeek-logs/*.log
        read_from: beginning

    transforms:
      parse_zeek:
        type: remap
        inputs: [zeek_logs]
        source: |
          .timestamp = now()
          .environment = "bc-xdr"
          .source_host = get_hostname!()
          .log_file = replace!(.file, "/zeek-logs/", "")

    sinks:
      cloudwatch:
        type: aws_cloudwatch_logs
        inputs: [parse_zeek]
        group_name: /bc-xdr/zeek
        stream_name: "{{ source_host }}/{{ log_file }}"
        region: eu-central-1
        encoding:
          codec: json
    VECTORCONF

    docker run -d \
      --name vector \
      --restart always \
      -v /opt/zeek/logs:/zeek-logs:ro \
      -v /opt/vector/vector.yaml:/etc/vector/vector.yaml:ro \
      timberio/vector:latest-alpine
  EOF
  )

  tags = merge(local.common_tags, { Name = "bc-xdr-test" })
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------

output "xdr_test_instance_id" {
  description = "SSM connect: aws ssm start-session --target <id>"
  value       = aws_instance.xdr_test.id
}

output "xdr_test_private_ip" {
  value       = aws_instance.xdr_test.private_ip
}

# EKS removed from XDR VPC by design.
# Security tooling pipelines run in bc-ctrl and bc-prd EKS clusters.
# This VPC hosts only the inline inspection EC2 (Zeek + Suricata + Vector).
