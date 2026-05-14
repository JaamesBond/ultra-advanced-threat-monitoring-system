# Commented for now as it is quite expensive to run, uncomment before demo

# resource "aws_instance" "splunk_soar_ec2" {
#   ami                         = "ami-00f1f079c46642ed1"
#   instance_type               = "t3.xlarge"
#   subnet_id                   = module.vpc.private_subnet_ids[0]
#   associate_public_ip_address = false
#   vpc_security_group_ids      = [aws_security_group.splunk_soar_ec2_sg.id]
#   iam_instance_profile        = aws_iam_instance_profile.splunk_soar_ec2.name

#   root_block_device {
#     volume_size           = 100
#     volume_type           = "gp3"
#     encrypted             = true
#     delete_on_termination = true
#   }

#   tags = merge(local.common_tags, { Name = "splunk-soar-ec2" })
# }

# resource "aws_security_group" "splunk_soar_ec2_sg" {
#   name        = "splunk-soar-ec2-sg"
#   description = "Splunk SOAR EC2 security group"
#   vpc_id      = module.vpc.vpc_id

#   egress {
#     description = "All outbound"
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = merge(local.common_tags, { Name = "splunk-soar-ec2-sg" })
# }

# resource "aws_iam_role" "splunk_soar_ec2" {
#   name = "splunk-soar-ec2-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Action    = "sts:AssumeRole"
#       Effect    = "Allow"
#       Principal = { Service = "ec2.amazonaws.com" }
#     }]
#   })

#   tags = merge(local.common_tags, { Name = "splunk-soar-ec2-role" })
# }

# resource "aws_iam_role_policy_attachment" "splunk_soar_ec2_ssm" {
#   role       = aws_iam_role.splunk_soar_ec2.name
#   policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# }

# resource "aws_iam_instance_profile" "splunk_soar_ec2" {
#   name = "splunk-soar-ec2-profile"
#   role = aws_iam_role.splunk_soar_ec2.name

#   tags = merge(local.common_tags, { Name = "splunk-soar-ec2-profile" })
# }

# resource "aws_route53_record" "splunk_soar_dns_record" {
#   zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
#   name    = "splunk-soar.bc-ctrl.internal"
#   type    = "A"
#   ttl     = 60
#   records = [aws_instance.splunk_soar_ec2.private_ip]

#   depends_on = [ aws_instance.splunk_soar_ec2 ]
# }