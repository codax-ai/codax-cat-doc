  FROM node:latest
  LABEL description="for build codax-cat-doc."
  WORKDIR /docs
  RUN npm install -g docsify-cli@latest
  COPY ./docs .
  EXPOSE 3000/tcp
  ENTRYPOINT docsify serve .