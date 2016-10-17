FROM debian:testing
MAINTAINER Alban Linard <alban@linard.fr>

ADD . /src/cosy/editor
RUN apt-get  update  --yes
RUN apt-get  install --yes git libssl-dev luajit luarocks
RUN luarocks install luasec
RUN cd /src/cosy/editor/ && \
    luarocks install https://raw.githubusercontent.com/un-def/hashids.lua/master/hashids-1.0.2-1.rockspec
    luarocks make rockspec/cosy-editor-master-1.rockspec && \
    cd /
RUN cd /src/cosy/editor/ && \
    mkdir -p /usr/share/cosy/editor/ && \
    git rev-parse --abbrev-ref HEAD > /usr/share/cosy/editor/VERSION && \
    cd /
RUN rm -rf /src/cosy/editor
ENTRYPOINT ["cosy-editor"]
CMD ["--help"]
