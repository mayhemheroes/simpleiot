RECOMMENDED_ELM_VERSION=0.19.0

if [ -z "$GOPATH" ]; then
  export GOPATH=~/go
fi

export GOBIN=$GOPATH/bin

siot_install_frontend_deps() {
  (cd frontend &&
    npm install elm &&
    npm install elm-spa)
}

siot_install_backend_deps() {
  go get -u github.com/benbjohnson/genesis/...
  go get -u golang.org/x/lint/golint
}

siot_check_elm() {
  if ! npx elm --version >/dev/null 2>&1; then
    echo "Please install elm >= 0.19"
    echo "https://guide.elm-lang.org/install.html"
    return 1
  fi

  version=$(npx elm --version)
  if [ "$version" != "$RECOMMENDED_ELM_VERSION" ]; then
    echo "found elm $version, recommend elm version $RECOMMENDED_ELM_VERSION"
    echo "not sure what will happen otherwise"
  fi

  return 0
}

siot_setup() {
  go mod download
  go install github.com/benbjohnson/genesis/... || return 1
  siot_check_elm || return 1
  siot_check_gopath_bin || return 1
  return 0
}

siot_build_frontend() {
  rm -f frontend/output/*
  (cd frontend && npx elm make src/Main.elm --output=output/elm.js) || return 1
  cp frontend/public/* frontend/output/ || return 1
  cp docs/simple-iot-app-logo.png frontend/output/ || return 1
  return 0
}

siot_build_assets() {
  mkdir -p assets/frontend || return 1
  $GOBIN/genesis -C frontend/output -pkg frontend \
    index.html \
    elm.js \
    main.js \
    ble.js \
    simple-iot-app-logo.png \
    >assets/frontend/assets.go || return 1
  return 0
}

siot_build_dependencies() {
  siot_build_frontend || return 1
  siot_build_assets || return 1
  return 0
}

siot_build() {
  siot_build_dependencies || return 1
  go build -o siot cmd/siot/main.go || return 1
  return 0
}

siot_deploy() {
  siot_build_dependencies || return 1
  gcloud app deploy cmd/portal || return 1
  return 0
}

siot_run() {
  siot_build_dependencies || return 1
  go run cmd/siot/main.go || return 1
  return 0
}

siot_run_device_sim() {
  go run cmd/siot/main.go -sim || return 1
  return 0
}

siot_build_docs() {
  # download snowboard binary from: https://github.com/bukalapak/snowboard/releases
  # and stash in /usr/local/bin
  snowboard lint docs/api.apib || return 1
  snowboard html docs/api.apib -o docs/api.html || return 1
}

# please run the following before pushing -- best if your editor can be set up
# to do this automatically.
siot_test() {
  siot_build_dependencies
  go fmt ./...
  go test "$@" ./... || return 1
  $GOBIN/golint -set_exit_status ./... || return 1
  go vet ./... || return 1
  return 0
}
