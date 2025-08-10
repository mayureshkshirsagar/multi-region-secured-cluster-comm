#!/usr/bin/env bash

aws ssm start-session --region $(terraform output -raw region_b) --target $(terraform output -raw c2_bastion_instance_id)
