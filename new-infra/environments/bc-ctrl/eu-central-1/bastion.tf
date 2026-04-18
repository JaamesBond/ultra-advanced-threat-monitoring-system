resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion" {
  key_name   = "bc-bastion-key"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Allow SSH inbound"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "bastion-sg" })
}

resource "aws_instance" "bastion" {
  ami                         = "ami-0a457777ab864ed6f" # Amazon Linux 2023 x86_64
  instance_type               = "t3.nano"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.bastion.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]

  tags = merge(local.common_tags, { Name = "bastion-host" })
}

output "bastion_public_ip" {
  description = "Public IP of the Bastion Host"
  value       = aws_instance.bastion.public_ip
}

resource "aws_secretsmanager_secret" "bastion_key" {
  name        = "bc/bastion/ssh-private-key"
  description = "Private SSH key for the Bastion host"
  
  # Ensure secret gets recreated if destroyed
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "bastion_key" {
  secret_id     = aws_secretsmanager_secret.bastion_key.id
  secret_string = tls_private_key.bastion.private_key_pem
}
