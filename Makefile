# PowerScale CSI on Kubernetes, common commands.
# Run `make help` for the list.

.PHONY: help test fmt validate helm cluster demo clean

help:
	@echo "make test      run the 9 manifest tests"
	@echo "make fmt       check Terraform formatting"
	@echo "make validate  validate Terraform"
	@echo "make helm      render the Dell CSI driver with project values"
	@echo "make cluster   create the kind cluster"
	@echo "make demo      run the full demo and four drills"
	@echo "make clean     remove Terraform and Python caches"

test:
	python3 -m unittest discover -s python/tests -v

fmt:
	cd terraform && terraform fmt -check

validate:
	cd terraform && terraform init -backend=false -input=false && terraform validate

helm:
	helm repo add dell https://dell.github.io/helm-charts
	helm repo update
	helm template isilon dell/csi-isilon --version 2.18.1 --namespace csi-isilon -f helm/values.yaml

cluster:
	bash scripts/setup_kind.sh

demo:
	bash scripts/run_demo.sh

clean:
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl python/tests/__pycache__
