# Cloud Run deploy posture for relay.verum.sh (alternative to app.yaml/GAE).
# Zero external deps — pure node:http. TLS terminated by Cloud Run.
#
# NOTE: in-memory ephemeral state — deploy with --min-instances=1 --max-instances=1
# (or add a shared store before scaling). See app.yaml for the rationale.
#
# Build+run locally:   docker build -t verum-signin-relay . && docker run -p 8080:8080 verum-signin-relay
# Deploy (operator go only):
#   gcloud run deploy verum-signin-relay --source . --region <r> \
#     --min-instances=1 --max-instances=1 --allow-unauthenticated
FROM node:22-slim
WORKDIR /app
COPY verum-signin-relay.ts ./
ENV PORT=8080
EXPOSE 8080
USER node
CMD ["node", "--experimental-strip-types", "verum-signin-relay.ts"]
