FROM ruby:2.4.1-alpine3.6

ENV GROK_DIR=/opt/grokdebug
ENV GIT_COMMIT=7e108f4b0469adebea158ab68956f84b273629b6
ENV BUILD_PACKAGES="git make gcc musl-dev linux-headers"

RUN apk update
RUN apk add $BUILD_PACKAGES
RUN git clone https://github.com/nickethier/grokdebug.git $GROK_DIR
WORKDIR $GROK_DIR
RUN git checkout $GIT_COMMIT
RUN sed -i 's/gem '"'"'haml'"'"'/gem '"'"'haml'"'"', '"'"'4.0.7'"'"'/g' Gemfile
RUN sed -i '/gem .json./d' Gemfile && echo "gem 'json', '2.1.0'" >> Gemfile
RUN sed -i '/unicorn/d' Gemfile
# RUN gem update
RUN gem install json -v '2.1.0'
RUN gem install raindrops -v '0.19.0'
RUN gem install haml -v '4.0.0'
RUN bundle install
WORKDIR /
RUN apk del $BUILD_PACKAGES --purge

WORKDIR $GROK_DIR

CMD ["rackup", "-o", "0.0.0.0", "-p", "80"]
