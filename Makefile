# PowerScale CSI on Kubernetes, common commands.
# Run `make help` for the list.

.PHONY: help test fmt validate helm cluster demo eks-deploy eks-demo eks-destroy clean

help:
	@echo "make test      run the 40 manifest/Terraform/guard tests"
	@echo "make fmt       check Terraform formatting"
	@echo "make validate  validate Terraform"
	@echo "make helm      render the Dell CSI driver with project values"
	@echo "make cluster   create the kind cluster"
	@echo "make demo      run the full demo and four drills"
	@echo "make eks-deploy  deploy the EKS path (real AWS, ~$4.50/day)"
	@echo "make eks-demo    run the EKS drills (timed node drain)"
	@echo "make eks-destroy destroy the EKS lab the same day"
	@echo "make clean     remove Terraform and Python caches"

test:
	python3 -m unittest discover -s python/tests -v

fmt:
	cd terraform && terraform fmt -check
	cd terraform/fis && terraform fmt -check

validate:
	cd terraform && terraform init -backend=false -input=false && terraform validate
	cd terraform/fis && terraform init -backend=false -input=false && terraform validate

helm:
	helm repo add dell https://dell.github.io/helm-charts
	helm repo update
	helm template isilon dell/csi-isilon --version 2.18.1 --namespace csi-isilon -f helm/values.yaml

cluster:
	bash scripts/setup_kind.sh

demo:
	bash scripts/run_demo.sh

eks-deploy:
	bash scripts/eks/deploy_eks.sh

eks-demo:
	bash scripts/eks/run_eks_demo.sh

eks-destroy:
	bash scripts/eks/destroy_eks.sh

clean:
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl terraform/fis/.terraform terraform/fis/.terraform.lock.hcl python/tests/__pycache__ guard/__pycache__
