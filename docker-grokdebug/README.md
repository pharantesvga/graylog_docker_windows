# docker-grokdebug

Aqui você executa um aplicação para padrões Grok em um container.

## How to build:

`docker-compose build`

**or**

`docker build . -t <your preferred tag>`

## How to start:

`docker-compose up -d`

**or**

`docker run -p 127.0.0.1:8080:80 -d lunderhage/grokdebug`
