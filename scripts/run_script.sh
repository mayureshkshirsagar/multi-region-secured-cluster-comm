. .venv/bin/activate
python verify_privatelink_connectivity.py --region-c1 us-east-1 --region-c2 us-west-2 --nlb-name k8s-default-echolb-06040fa13f --service-name com.amazonaws.vpce.us-west-2.vpce-svc-09aa14c33a0f9d42f --kubectl-context-c1 C1 --target-host vpce-09fd909182fb354fc-esniax7u.vpce-svc-09aa14c33a0f9d42f.us-west-2.vpce.amazonaws.com
deactivate