# Build context: apps/   (docker build -f apps/orders-api/Dockerfile apps/)
# Espelho público do Docker Official Image no ECR Public (evita rate limit do Docker Hub)
FROM public.ecr.aws/docker/library/python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app/shared

WORKDIR /app
COPY shared/requirements-base.txt shared/requirements-base.txt
COPY orders-api/requirements.txt service/requirements.txt
RUN cd service && pip install -r requirements.txt

COPY shared/workshop_common shared/workshop_common
COPY orders-api/app service/app

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001
WORKDIR /app/service
EXPOSE 8080
CMD ["python", "-m", "app"]
