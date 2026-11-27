# syntax=docker/dockerfile:1
# Rocketsled with this example's configs and skins. PAAS picks which one runs.
ARG ROCKETSLED_IMAGE=rocketsled:local
FROM ${ROCKETSLED_IMAGE}
COPY fauxroku.yaml fauxcel.yaml /app/
COPY skins /app/skins
ENV PAAS=fauxroku
ENTRYPOINT ["sh", "-c", "exec rocketsled serve -config /app/$PAAS.yaml -env-file /dev/null"]
