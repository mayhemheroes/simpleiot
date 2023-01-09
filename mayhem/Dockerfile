FROM golang:1.18 as builder

COPY . /simpleiot
WORKDIR /simpleiot/mayhem

RUN go install github.com/dvyukov/go-fuzz/go-fuzz@latest github.com/dvyukov/go-fuzz/go-fuzz-build@latest
RUN go get github.com/dvyukov/go-fuzz/go-fuzz-dep
RUN apt update && apt install -y clang


RUN go-fuzz-build -libfuzzer -o fuzzToken.a && \
    clang -fsanitize=fuzzer fuzzToken.a -o fuzzToken.libfuzzer

FROM debian:bookworm-slim
COPY --from=builder /simpleiot/mayhem/fuzzToken.libfuzzer /