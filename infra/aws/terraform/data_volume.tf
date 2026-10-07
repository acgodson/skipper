# The two SQLite files live here and nowhere else. They are not on the root volume,
# because a root volume belongs to the instance: replacing the box replaces it, and an
# instance replacement must never be able to take rc-api.db and rc-api-claims.db with it.
# This volume outlives every instance that mounts it, and prevent_destroy means Terraform
# refuses to remove it even when the configuration stops mentioning it.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  type              = "gp3"
  size              = var.data_volume_gb
  iops              = var.data_volume_iops
  throughput        = var.data_volume_throughput
  encrypted         = true

  tags = { Name = "${local.name}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

# stop_instance_before_detaching makes a detach an orderly shutdown rather than the
# equivalent of pulling the disk out from under an open SQLite file.
resource "aws_volume_attachment" "data" {
  device_name                    = var.data_volume_device_name
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.app.id
  stop_instance_before_detaching = true
}
