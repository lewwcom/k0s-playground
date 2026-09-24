highlight_style = \033[1;36m
color_off = \033[0m
target_name_width = 30
print_headline = @echo; echo "${highlight_style}${1}${color_off}"

# Make sure these env vars are set before calling, since there is no committer
# info otherwise:
#
#   GIT_AUTHOR_NAME=gogs-admin
#   GIT_COMMITTER_NAME=gogs-admin
#   EMAIL=gogs-admin@local
#
# Also set, since git run as root may otherwise fail with "detected dubious
# ownership" (the repo isn't owned by root):
#
#   GIT_CONFIG_COUNT=1
#   GIT_CONFIG_KEY_0=safe.directory
#   GIT_CONFIG_VALUE_0=*
#
# -E is required to preserve all of these through sudo; without it, sudo's
# env_reset strips them.
#
# When USE_SUDO is set, git objects touched by this end up root-owned —
# call gitz_cleanup afterward to restore the original owner.
gitz = $(if ${USE_SUDO},sudo -E git,git)

GITDIR := $(shell git rev-parse --git-dir)
GITDIR_OWNER  := $(shell ls -dln $(GITDIR) | awk '{print $$3 ":" $$4}')
gitz_cleanup = $(if ${USE_SUDO},sudo chown -R $(GITDIR_OWNER) "$(GITDIR)",)

dockerz = $(if ${USE_SUDO},sudo docker,docker)
kubectlz = $(dockerz) exec --interactive k0s-controller k0s kubectl "$$@"

# Ref: https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
# Define target with help: <target>: <dep> ## <description>
help:
	@grep --extended-regexp '^[a-zA-Z0-9_-]+:.*?## .*$$' Makefile | \
	sort | \
	awk '\
	BEGIN {FS = ":.*?## "}; \
	{printf "${highlight_style}%-${target_name_width}s${color_off} %s\n", $$1, $$2}'

# include .env
# Modify to interact with k0s-controller deployed in different host. deploy-k0s
# target doesn't support this
K0S_HOST ?= localhost

gen-kubeconfig: ## Generate kubeconfig
	@$(dockerz) exec k0s-controller k0s kubeconfig admin | \
	yq --yaml-output '.clusters[0].name = "k0s" | .clusters[0].cluster.server = "https://${K0S_HOST}:6443" | .contexts[0].name = "k0s" | .contexts[0].context.cluster = "k0s" | ."current-context" = "k0s"'

deploy-k0s: ## Deploy k0s cluster with ArgoCD and Gogs
	$(call print_headline,"Deploy k0s cluster with ArgoCD and Gogs")
	./bootstrap-k0s.sh

set-up-gogs-repo: ## Set up Gogs repository
	$(call print_headline,"Waiting for Gogs to be ready...")
	until curl --fail http://${K0S_HOST}:30018/healthcheck > /dev/null 2>&1; do :; done

	$(call print_headline,"Set up Gogs repository")
	curl --request POST --url http://${K0S_HOST}:30018/api/v1/users/gogs-admin/tokens \
	--user gogs-admin:password \
	--header 'Content-Type: application/json' \
	--data '{"name": "$(shell date +%s | tail -c 5)"}' | jq --raw-output '.sha1' > /tmp/$@.tmp

	@echo -n "Token: "; cat /tmp/$@.tmp; echo

	curl --request DELETE --url http://${K0S_HOST}:30018/api/v1/repos/gogs-admin/k0s \
	--header "Authorization: token $$(cat /tmp/$@.tmp | tr -d '\n')" || true

	curl --request POST --url http://${K0S_HOST}:30018/api/v1/user/repos \
	--header "Authorization: token $$(cat /tmp/$@.tmp | tr -d '\n')" \
	--header 'Content-Type: application/json' \
	--data '{"name": "k0s"}' | jq

	$(gitz) remote remove gogs 2> /dev/null || true
	$(gitz) remote add gogs http://gogs-admin:$$(cat /tmp/$@.tmp | tr -d '\n')@${K0S_HOST}:30018/gogs-admin/k0s.git
	@$(gitz_cleanup)

	@rm /tmp/$@.tmp

wait-argocd-app: ## Wait for ArgoCD application to be ready (Usage: make APP=<app> wait-argocd-app)
	$(call print_headline,"Waiting for ${APP} to be ready...")
	$(kubectlz) --namespace argocd wait application/${APP} --for jsonpath='{.status.operationState.phase}'=Succeeded --timeout=15m
	$(kubectlz) --namespace argocd wait application/${APP} --for jsonpath='{.status.sync.status}'=Synced --timeout=15m
	$(kubectlz) --namespace argocd wait application/${APP} --for jsonpath='{.status.health.status}'=Healthy --timeout=15m

destroy-k0s: ## Destroy k0s cluster
	$(call print_headline,"Destroy k0s cluster")
	$(dockerz) compose down --volumes

commit-to-gogs: ## Commit to Gogs
	$(call print_headline,"Commit to Gogs")
	$(gitz) add .
	$(gitz) commit --message "Commit to Gogs" --allow-empty
	$(gitz) push --force gogs master
	$(gitz) reset --mixed HEAD~
	@$(gitz_cleanup)

