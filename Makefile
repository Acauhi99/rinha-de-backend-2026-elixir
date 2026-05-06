.PHONY: up down logs smoke bench prepare-submission replay-8777799

up:
	docker compose -f docker-compose.local.yml up -d --build

down:
	docker compose -f docker-compose.local.yml down --remove-orphans

logs:
	docker compose -f docker-compose.local.yml logs -f

smoke:
	./scripts/smoke-local.sh

bench:
	./scripts/bench-local.sh

prepare-submission:
	./scripts/prepare-submission.sh

replay-8777799:
	./scripts/replay-preview-8777799.sh
