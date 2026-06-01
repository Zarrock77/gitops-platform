# Thin wrapper around platform.sh so `make up` works on macOS/Linux while the
# real logic stays in one portable shell script (also runnable from Git Bash).
SH := ./platform.sh

.PHONY: up demo configure bootstrap build test status info password down help

help:        ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

up:          ## Cluster + ingress + ArgoCD + build/import image
	@$(SH) up

demo:        ## Deploy app + monitoring locally via Helm (no GitHub)
	@$(SH) demo

configure:   ## Set GitHub user: make configure USER=youruser
	@$(SH) configure $(USER)

bootstrap:   ## Register the App-of-Apps root (GitOps from GitHub)
	@$(SH) bootstrap

build:       ## Build the app image
	@$(SH) build

test:        ## Run Go tests in a container
	@$(SH) test

status:      ## Show ArgoCD apps and pods
	@$(SH) status

info:        ## Print access URLs
	@$(SH) info

password:    ## Print the initial ArgoCD admin password
	@$(SH) argocd-password

down:        ## Delete the cluster
	@$(SH) down
