# Build context: apps/   (docker build -f apps/bff-api/Dockerfile apps/)
# Espelho público do Docker Official Image no ECR Public (evita rate limit do Docker Hub)
# Fixada por digest (índice multi-arch: amd64 e arm64); a tag é só legível. Atualize os dois juntos:
#   docker buildx imagetools inspect public.ecr.aws/docker/library/python:3.12-slim   (linha "Digest:")
FROM public.ecr.aws/docker/library/python:3.12.15-slim-trixie@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app/shared

WORKDIR /app
# Lock completo com hashes (scripts/lock.sh): instala exatamente esses pacotes, nada resolvido no build.
COPY bff-api/requirements.lock service/requirements.lock
RUN pip install --require-hashes --no-deps -r service/requirements.lock

COPY shared/workshop_common shared/workshop_common
COPY bff-api/app service/app

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001
WORKDIR /app/service
EXPOSE 8080
CMD ["python", "-m", "app"]
