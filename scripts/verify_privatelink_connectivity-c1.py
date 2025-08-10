#!/usr/bin/env python3
"""
verify_privatelink_connectivity.py
Usage:
  python verify_privatelink_connectivity.py \
    --region-c1 us-east-1 \
    --region-c2 us-west-2 \
    --nlb-name <nlb-name> \
    --service-name com.amazonaws.vpce-svc-xxxxxxxx \
    --kubectl-context-c1 C1 \
    --target-host <interface-endpoint-dns>

Requires: python3, boto3, kubectl configured with a context for C1
"""

import boto3, subprocess, json, argparse, sys


def run(cmd: str):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def check_nlb_internal(elbv2_client, nlb_name: str) -> bool:
    resp = elbv2_client.describe_load_balancers(Names=[nlb_name])
    lb = resp["LoadBalancers"][0]
    scheme = lb["Scheme"]
    print(f"NLB {nlb_name} scheme = {scheme}")
    return scheme == "internal"


def check_vpc_endpoint_service(ec2_client, svc_name: str) -> bool:
    resp = ec2_client.describe_vpc_endpoint_services(ServiceNames=[svc_name])
    details = resp.get("ServiceDetails", [])
    print("Service details count:", len(details))
    return len(details) > 0


def check_interface_endpoint(ec2_client, svc_name: str) -> bool:
    resp = ec2_client.describe_vpc_endpoints(
        Filters=[{"Name": "service-name", "Values": [svc_name]}]
    )
    vps = resp.get("VpcEndpoints", [])
    print("Found interface endpoint(s):", [ve["VpcEndpointId"] for ve in vps])
    return len(vps) > 0


def kubectl_exec(context: str, label_selector: str, url: str):
    r = run(f"kubectl --context {context} get pods -l {label_selector} -o json")
    if r.returncode != 0:
        print("kubectl get pods failed:", r.stderr)
        return False, r.stderr
    pods = json.loads(r.stdout).get("items", [])
    if not pods:
        print("No pod found for label", label_selector)
        return False, "no pod"
    pod = pods[0]["metadata"]["name"]
    print("Using pod", pod)
    r2 = run(f"kubectl --context {context} exec {pod} -- curl -s -S -m 5 {url}")
    return r2.returncode == 0, (r2.stdout if r2.returncode == 0 else r2.stderr)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--region-c1", required=True)
    ap.add_argument("--region-c2", required=True)
    ap.add_argument("--nlb-name", required=True)
    ap.add_argument("--service-name", required=True)
    ap.add_argument("--kubectl-context-c1", required=True)
    ap.add_argument("--test-pod-label", default="app=testclient")
    ap.add_argument("--target-host", required=True)
    args = ap.parse_args()

    session_c2 = boto3.session.Session(region_name=args.region_c2)
    elbv2 = session_c2.client("elbv2")
    ec2_c2 = session_c2.client("ec2")

    print("Checking that NLB is internal...")
    if not check_nlb_internal(elbv2, args.nlb_name):
        print("FAIL: NLB is not internal or not found.")
        sys.exit(2)

    print("Checking VPC endpoint service exists (C2)...")
    if not check_vpc_endpoint_service(ec2_c2, args.service_name):
        print("FAIL: VPC Endpoint Service not found.")
        sys.exit(2)

    session_c1 = boto3.session.Session(region_name=args.region_c1)
    ec2_c1 = session_c1.client("ec2")
    print("Checking interface endpoint exists in C1...")
    if not check_interface_endpoint(ec2_c1, args.service_name):
        print("FAIL: Interface endpoint missing in C1.")
        sys.exit(2)

    urls = [
        "k8s-default-echolb-06040fa13f-3905dc5f1dde1231.elb.us-west-2.amazonaws.com",
        "k8s-default-echo2lb-12c7555b49-6d69b41e1aef55f6.elb.us-west-2.amazonaws.com",
        "https://5C4A062CF3B9017E85BE38BC92AE40F5.gr7.us-west-2.eks.amazonaws.com",
        f"{args.target_host}",
    ]
    ports = [53, 443, 8443, 5443, 5678, 6443, 9443, 80]

    successful_endpoints = []
    unsuccessful_endpoints = []
    for url in urls:
        for port in ports:
            # url = f"http://{args.target_host}:{port}"
            _url = f"{url}:{port}"
            print("Curl from test pod in C1 to target host:", _url)
            ok, out = kubectl_exec(args.kubectl_context_c1, args.test_pod_label, _url)
            if ok:
                print("SUCCESS: Pod reached service. Response snippet:", out[:400])
                successful_endpoints.append(_url)
                # sys.exit(0)
            else:
                print("FAIL: Pod could not reach the service. Error:", out)
                unsuccessful_endpoints.append(_url)
                # sys.exit(3)

    print("Unsuccessful endpoints:")
    for url in unsuccessful_endpoints:
        print(f"{url} failed")
    print("\nSuccessful endpoints:")
    for url in successful_endpoints:
        print(f"{url} succeeded")
