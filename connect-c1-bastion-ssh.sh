#!/usr/bin/env bash

ssh -i bastion.pem ec2-user@$(terraform output -raw c1_bastion_public_ip)
