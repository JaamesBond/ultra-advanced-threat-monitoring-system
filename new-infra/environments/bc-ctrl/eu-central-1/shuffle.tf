data "aws_ami" "ubuntu-2404" {
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

resource "aws_instance" "shuffle_ec2" {
  ami                         = data.aws_ami.ubuntu-2404.id
  instance_type               = "t3.large"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.shuffle_ec2_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.shuffle_ec2.name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-EOT
              #!/bin/bash
              apt update
              apt install -y ca-certificates curl gnupg unzip wget
              sudo install -m 0755 -d /etc/apt/keyrings
              sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
              sudo chmod a+r /etc/apt/keyrings/docker.asc
              
              sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
              Types: deb
              URIs: https://download.docker.com/linux/ubuntu
              Suites: $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$VERSION_CODENAME}")
              Components: stable
              Architectures: $(dpkg --print-architecture)
              Signed-By: /etc/apt/keyrings/docker.asc
              EOF

              apt update
              apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

              cd /opt
              wget https://github.com/Shuffle/Shuffle/archive/refs/tags/v2.2.0.zip -O shuffle.zip
              unzip shuffle.zip
              cd Shuffle-2.2.0
              sudo chown -R 1000:1000 shuffle-database
              
              sysctl -w vm.max_map_count=262144
              echo "vm.max_map_count=262144" >> /etc/sysctl.conf
              swapoff -a

              docker compose up -d
              EOT

  tags = merge(local.common_tags, { Name = "shuffle-ec2" })
}

resource "aws_security_group" "shuffle_ec2_sg" {
  name        = "shuffle-ec2-sg"
  description = "Shuffle EC2 security group"
  vpc_id      = module.vpc.vpc_id

  # Shuffle HTTP from bc-ctrl
ingress {
    description      = "Shuffle HTTP from internet"
    from_port        = 3001
    to_port          = 3001
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
}

ingress {
    description      = "Shuffle HTTPS from internet"
    from_port        = 3443
    to_port          = 3443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
}

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "shuffle-ec2-sg" })
}

resource "aws_iam_role" "shuffle_ec2" {
  name = "shuffle-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "shuffle-ec2-role" })
}

resource "aws_iam_role_policy_attachment" "shuffle_ec2_ssm" {
  role       = aws_iam_role.shuffle_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "shuffle_ec2" {
  name = "shuffle-ec2-profile"
  role = aws_iam_role.shuffle_ec2.name

  tags = merge(local.common_tags, { Name = "shuffle-ec2-profile" })
}