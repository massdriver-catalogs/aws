FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /gamelab .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /gamelab /gamelab
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/gamelab"]
