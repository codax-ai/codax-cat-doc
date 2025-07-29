> 部署规划：
> 1. 一个 MySQL8 数据库
> 2. 一个 Hadoop 集群（暂无，本文使用单实例本地存储）
> 3. 一个 K8s 集群，其中业务使用命名空间 test，Cat 使用命名空间 cat

### 准备镜像
---

1. 拉取代码及 Maven 依赖，现在无需额外配置即可拉取全部依赖

```bash
git clone --depth=1 https://github.com/dianping/cat.git
```

2. 4.0-RC1 源码问题修改（可选）

<details>
<summary>修改默认管理员密码取配置/环境变量</summary>

```java
// Component
public class DefaultCatPropertyProvider implements CatPropertyProvider {
    public String getProperty(final String name, final String defaultValue) {
        String value = null;

        // try to get value from system properties, -D<name>=<value>
        if (value == null) {
            value = System.getProperty(name);
        }

        // try to get value from environment variable
        if (value == null) {
            value = System.getenv(name);
        }

        if (StringUtils.isBlank(value)) {
            return defaultValue;
        }
        return value;
    }
}
```

</details>

3. 进入项目根目录，docker 镜像打包（相关文件都在项目 docker 目录下）。注意：

- Windows 开发环境需要修改 datasources.sh 文件的编码换行格式从 CRLF 改为 LF，否则容器启动会报错找不到 env bash
- 如果打镜像报错无法拉取基础镜像，可以先手动拉取基础镜像`docker pull maven:3.8.4-openjdk-8`、
  `docker pull tomcat:8.5.41-jre8-alpine`

```bash
docker build -f docker/Dockerfile -t cat:4.0.0 .
```

3. 镜像打标签（以阿里云 ACR 为例）

```bash
docker tag cat:4.0.0 registry.cn-shanghai.aliyuncs.com/my_registry/cat:4.0.0
```

4. 推送镜像到镜像仓库（以阿里云 ACR 为例）

```bash
docker push registry.cn-shanghai.aliyuncs.com/my_registry/cat:4.0.0
```

<details>
<summary>docker 相关脚本</summary>

Dockerfile

```bash
FROM maven:3.8.4-openjdk-8 as mavenrepo

WORKDIR /app
COPY cat-alarm cat-alarm
COPY cat-consumer cat-consumer
COPY cat-hadoop cat-hadoop
COPY cat-client cat-client
COPY cat-core cat-core
COPY cat-home cat-home
COPY pom.xml pom.xml
RUN mvn clean package -DskipTests

FROM tomcat:8.5.41-jre8-alpine
ENV TZ=Asia/Shanghai
COPY --from=mavenrepo /app/cat-home/target/cat-home.war /usr/local/tomcat/webapps/cat.war
COPY docker/datasources.xml /data/appdatas/cat/datasources.xml
COPY docker/datasources.sh datasources.sh
RUN sed -i "s/port=\"8080\"/port=\"8080\"\ URIEncoding=\"utf-8\"/g" $CATALINA_HOME/conf/server.xml && chmod +x datasources.sh
RUN ln -s /lib /lib64 \
    && apk add --no-cache bash tini libc6-compat linux-pam krb5 krb5-libs
    
CMD ["/bin/sh", "-c", "./datasources.sh && catalina.sh run"]

```

datasources.sh

```bash
#!/usr/bin/env bash
sed -i "s/MYSQL_URL/${MYSQL_URL}/g" /data/appdatas/cat/datasources.xml;
sed -i "s/MYSQL_PORT/${MYSQL_PORT}/g" /data/appdatas/cat/datasources.xml;
sed -i "s/MYSQL_USERNAME/${MYSQL_USERNAME}/g" /data/appdatas/cat/datasources.xml;
sed -i "s/MYSQL_PASSWD/${MYSQL_PASSWD}/g" /data/appdatas/cat/datasources.xml;
sed -i "s/MYSQL_SCHEMA/${MYSQL_SCHEMA}/g" /data/appdatas/cat/datasources.xml;
```

datasources.xml

```xml
<?xml version="1.0" encoding="utf-8"?>

<data-sources>
    <data-source id="cat">
        <maximum-pool-size>3</maximum-pool-size>
        <connection-timeout>1s</connection-timeout>
        <idle-timeout>10m</idle-timeout>
        <statement-cache-size>1000</statement-cache-size>
        <properties>
            <driver>com.mysql.jdbc.Driver</driver>
            <url><![CDATA[jdbc:mysql://MYSQL_URL:MYSQL_PORT/MYSQL_SCHEMA]]></url>
            <user>MYSQL_USERNAME</user>
            <password>MYSQL_PASSWD</password>
            <connectionProperties>
                <![CDATA[useUnicode=true&characterEncoding=UTF-8&autoReconnect=true&socketTimeout=120000]]></connectionProperties>
        </properties>
    </data-source>
</data-sources>
```

</details>

### 初始化数据库
---

一套 Cat 集群只需要部署一个数据库。

在MySQL 8 中新建数据库 cat；执行项目中的 sql 脚本 script/CatApplication.sql，创建表结构。

<details>
<summary>sql 脚本</summary>

```sql
CREATE DATABASE cat DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE TABLE `dailyreport`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `name`          varchar(20) NOT NULL COMMENT '报表名称, transaction, problem...',
    `ip`            varchar(50) NOT NULL COMMENT '报表来自于哪台cat-consumer机器',
    `domain`        varchar(50) NOT NULL COMMENT '报表处理的Domain信息',
    `period`        datetime    NOT NULL COMMENT '报表时间段',
    `type`          tinyint(4)  NOT NULL COMMENT '报表数据格式, 1/xml, 2/json, 默认1',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `period` (`period`, `domain`, `name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='天报表';

CREATE TABLE `weeklyreport`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `name`          varchar(20) NOT NULL COMMENT '报表名称, transaction, problem...',
    `ip`            varchar(50) NOT NULL COMMENT '报表来自于哪台cat-consumer机器',
    `domain`        varchar(50) NOT NULL COMMENT '报表处理的Domain信息',
    `period`        datetime    NOT NULL COMMENT '报表时间段',
    `type`          tinyint(4)  NOT NULL COMMENT '报表数据格式, 1/xml, 2/json, 默认1',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `period` (`period`, `domain`, `name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='周报表';

CREATE TABLE `monthreport`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `name`          varchar(20) NOT NULL COMMENT '报表名称, transaction, problem...',
    `ip`            varchar(50) NOT NULL COMMENT '报表来自于哪台cat-consumer机器',
    `domain`        varchar(50) NOT NULL COMMENT '报表处理的Domain信息',
    `period`        datetime    NOT NULL COMMENT '报表时间段',
    `type`          tinyint(4)  NOT NULL COMMENT '报表数据格式, 1/xml, 2/json, 默认1',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `period` (`period`, `domain`, `name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='月报表';

CREATE TABLE `hostinfo`
(
    `id`                 int(11)      NOT NULL AUTO_INCREMENT,
    `ip`                 varchar(50)  NOT NULL COMMENT '部署机器IP',
    `domain`             varchar(200) NOT NULL COMMENT '部署机器对应的项目名',
    `hostname`           varchar(200) DEFAULT NULL COMMENT '机器域名',
    `creation_date`      datetime     NOT NULL,
    `last_modified_date` datetime     NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `ip_index` (`ip`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='IP和项目名的对应关系';

CREATE TABLE `hourlyreport`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `type`          tinyint(4)  NOT NULL COMMENT '报表类型, 1/xml, 9/binary 默认1',
    `name`          varchar(20) NOT NULL COMMENT '报表名称',
    `ip`            varchar(50) DEFAULT NULL COMMENT '报表来自于哪台机器',
    `domain`        varchar(50) NOT NULL COMMENT '报表项目',
    `period`        datetime    NOT NULL COMMENT '报表时间段',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    KEY `IX_Domain_Name_Period` (`domain`, `name`, `period`),
    KEY `IX_Name_Period` (`name`, `period`),
    KEY `IX_Period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='用于存放实时报表信息，处理之后的结果';

CREATE TABLE `hourly_report_content`
(
    `report_id`     int(11)  NOT NULL COMMENT '报表ID',
    `content`       longblob NOT NULL COMMENT '二进制报表内容',
    `period`        datetime NOT NULL COMMENT '报表时间段',
    `creation_date` datetime NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`report_id`),
    KEY `IX_Period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='小时报表二进制内容';

CREATE TABLE `daily_report_content`
(
    `report_id`     int(11)  NOT NULL COMMENT '报表ID',
    `content`       longblob NOT NULL COMMENT '二进制报表内容',
    `period`        datetime COMMENT '报表时间段',
    `creation_date` datetime NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`report_id`),
    KEY `IX_Period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='天报表二进制内容';

CREATE TABLE `weekly_report_content`
(
    `report_id`     int(11)  NOT NULL COMMENT '报表ID',
    `content`       longblob NOT NULL COMMENT '二进制报表内容',
    `period`        datetime COMMENT '报表时间段',
    `creation_date` datetime NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`report_id`),
    KEY `IX_Period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='周报表二进制内容';

CREATE TABLE `monthly_report_content`
(
    `report_id`     int(11)  NOT NULL COMMENT '报表ID',
    `content`       longblob NOT NULL COMMENT '二进制报表内容',
    `period`        datetime COMMENT '报表时间段',
    `creation_date` datetime NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`report_id`),
    KEY `IX_Period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='月报表二进制内容';

CREATE TABLE `businessReport`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `type`          tinyint(4)  NOT NULL COMMENT '报表类型 报表数据格式, 1/Binary, 2/xml , 3/json',
    `name`          varchar(20) NOT NULL COMMENT '报表名称',
    `ip`            varchar(50) NOT NULL COMMENT '报表来自于哪台机器',
    `productLine`   varchar(50) NOT NULL COMMENT '指标来源于哪个产品组',
    `period`        datetime    NOT NULL COMMENT '报表时间段',
    `content`       longblob COMMENT '用于存放报表的具体内容',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    KEY `IX_Period_productLine_name` (`period`, `productLine`, `name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8
  ROW_FORMAT = COMPRESSED COMMENT ='用于存放业务监控实时报表信息，处理之后的结果';

CREATE TABLE `task`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `producer`      varchar(20) NOT NULL COMMENT '任务创建者ip',
    `consumer`      varchar(20) NULL COMMENT '任务执行者ip',
    `failure_count` tinyint(4)  NOT NULL COMMENT '任务失败次数',
    `report_name`   varchar(20) NOT NULL COMMENT '报表名称, transaction, problem...',
    `report_domain` varchar(50) NOT NULL COMMENT '报表处理的Domain信息',
    `report_period` datetime    NOT NULL COMMENT '报表时间',
    `status`        tinyint(4)  NOT NULL COMMENT '执行状态: 1/todo, 2/doing, 3/done 4/failed',
    `task_type`     tinyint(4)  NOT NULL DEFAULT '1' COMMENT '0表示小时任务，1表示天任务',
    `creation_date` datetime    NOT NULL COMMENT '任务创建时间',
    `start_date`    datetime    NULL COMMENT '开始时间, 这次执行开始时间',
    `end_date`      datetime    NULL COMMENT '结束时间, 这次执行结束时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `task_period_domain_name_type` (`report_period`, `report_domain`, `report_name`, `task_type`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='后台任务';

CREATE TABLE `project`
(
    `id`               int(11)      NOT NULL AUTO_INCREMENT,
    `domain`           varchar(200) NOT NULL COMMENT '项目名称',
    `cmdb_domain`      varchar(200) DEFAULT NULL COMMENT 'cmdb项目名称',
    `level`            int(5)       DEFAULT NULL COMMENT '项目级别',
    `bu`               varchar(50)  DEFAULT NULL COMMENT 'CMDB事业部',
    `cmdb_productline` varchar(50)  DEFAULT NULL COMMENT 'CMDB产品线',
    `owner`            varchar(50)  DEFAULT NULL COMMENT '项目负责人',
    `email`            longtext     DEFAULT NULL COMMENT '项目组邮件',
    `phone`            longtext     DEFAULT NULL COMMENT '联系电话',
    `creation_date`    datetime     DEFAULT NULL COMMENT '创建时间',
    `modify_date`      datetime     DEFAULT NULL COMMENT '修改时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `domain` (`domain`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='项目基本信息';

CREATE TABLE `topologyGraph`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `ip`            varchar(50) NOT NULL COMMENT '报表来自于哪台cat-client机器ip',
    `period`        datetime    NOT NULL COMMENT '报表时间段,精确到分钟',
    `type`          tinyint(4)  NOT NULL COMMENT '报表数据格式, 1/xml, 2/json, 3/binary',
    `content`       longblob COMMENT '用于存放报表的具体内容',
    `creation_date` datetime    NOT NULL COMMENT '报表创建时间',
    PRIMARY KEY (`id`),
    KEY `period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='用于存储历史的拓扑图曲线';

CREATE TABLE `config`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `name`          varchar(50) NOT NULL COMMENT '配置名称',
    `content`       longtext COMMENT '配置的具体内容',
    `creation_date` datetime    NOT NULL COMMENT '配置创建时间',
    `modify_date`   datetime    NOT NULL COMMENT '配置修改时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `name` (`name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='用于存储系统的全局配置信息';

CREATE TABLE `baseline`
(
    `id`            int(11) NOT NULL AUTO_INCREMENT,
    `report_name`   varchar(100) DEFAULT NULL,
    `index_key`     varchar(100) DEFAULT NULL,
    `report_period` datetime     DEFAULT NULL,
    `data`          blob,
    `creation_date` datetime     DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `period_name_key` (`report_period`, `report_name`, `index_key`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8;

CREATE TABLE `alteration`
(
    `id`            int(11)      NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `type`          varchar(64)  NOT NULL COMMENT '分类',
    `title`         varchar(128) NOT NULL COMMENT '变更标题',
    `domain`        varchar(128) NOT NULL COMMENT '变更项目',
    `hostname`      varchar(128) NOT NULL COMMENT '变更机器名',
    `ip`            varchar(128) DEFAULT NULL COMMENT '变更机器IP',
    `date`          datetime     NOT NULL COMMENT '变更时间',
    `user`          varchar(45)  NOT NULL COMMENT '变更用户',
    `alt_group`     varchar(45)  DEFAULT NULL COMMENT '变更组别',
    `content`       longtext     NOT NULL COMMENT '变更内容',
    `url`           varchar(200) DEFAULT NULL COMMENT '变更链接',
    `status`        tinyint(4)   DEFAULT '0' COMMENT '变更状态',
    `creation_date` datetime     NOT NULL COMMENT '数据库创建时间',
    PRIMARY KEY (`id`),
    KEY `ind_date_domain_host` (`date`, `domain`, `hostname`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='变更表';

CREATE TABLE `alert`
(
    `id`            int(11)      NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `domain`        varchar(128) NOT NULL COMMENT '告警项目',
    `alert_time`    datetime     NOT NULL COMMENT '告警时间',
    `category`      varchar(64)  NOT NULL COMMENT '告警分类:network/business/system/exception -alert',
    `type`          varchar(64)  NOT NULL COMMENT '告警类型:error/warning',
    `content`       longtext     NOT NULL COMMENT '告警内容',
    `metric`        varchar(128) NOT NULL COMMENT '告警指标',
    `creation_date` datetime     NOT NULL COMMENT '数据插入时间',
    PRIMARY KEY (`id`),
    KEY `idx_alert_time_category_domain` (`alert_time`, `category`, `domain`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='存储告警信息';

CREATE TABLE `alert_summary`
(
    `id`            int(11)      NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `domain`        varchar(128) NOT NULL COMMENT '告警项目',
    `alert_time`    datetime     NOT NULL COMMENT '告警时间',
    `content`       longtext     NOT NULL COMMENT '统一告警内容',
    `creation_date` datetime     NOT NULL COMMENT '数据插入时间',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='统一告警信息';

CREATE TABLE `operation`
(
    `id`            int(11)      NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `user`          varchar(128) NOT NULL COMMENT '用户名',
    `module`        varchar(128) NOT NULL COMMENT '模块',
    `operation`     varchar(128) NOT NULL COMMENT '操作',
    `time`          datetime     NOT NULL COMMENT '修改时间',
    `content`       longtext     NOT NULL COMMENT '修改内容',
    `creation_date` datetime     NOT NULL COMMENT '数据插入时间',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='用户操作日志';

CREATE TABLE `overload`
(
    `id`            int(11)    NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `report_id`     int(11)    NOT NULL COMMENT '报告id',
    `report_type`   tinyint(4) NOT NULL COMMENT '报告类型 1:hourly 2:daily 3:weekly 4:monthly',
    `report_size`   double     NOT NULL COMMENT '报告大小 单位MB',
    `period`        datetime   NOT NULL COMMENT '报表时间',
    `creation_date` datetime   NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`id`),
    KEY `period` (`period`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='过大容量表';

CREATE TABLE `config_modification`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `user_name`     varchar(64) NOT NULL COMMENT '用户名',
    `account_name`  varchar(64) NOT NULL COMMENT '账户名',
    `action_name`   varchar(64) NOT NULL COMMENT 'action名',
    `argument`      longtext COMMENT '参数内容',
    `date`          datetime    NOT NULL COMMENT '修改时间',
    `creation_date` datetime    NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='配置修改记录表';

CREATE TABLE `user_define_rule`
(
    `id`            int(11)  NOT NULL AUTO_INCREMENT COMMENT '自增长ID',
    `content`       text     NOT NULL COMMENT '用户定义规则',
    `creation_date` datetime NOT NULL COMMENT '创建时间',
    PRIMARY KEY (`id`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='用户定义规则表';

CREATE TABLE `business_config`
(
    `id`         int(11)     NOT NULL AUTO_INCREMENT,
    `name`       varchar(20) NOT NULL DEFAULT '' COMMENT '配置名称',
    `domain`     varchar(50) NOT NULL DEFAULT '' COMMENT '项目',
    `content`    longtext COMMENT '配置内容',
    `updatetime` datetime    NOT NULL,
    PRIMARY KEY (`id`),
    KEY `updatetime` (`updatetime`),
    KEY `name_domain` (`name`, `domain`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8;

CREATE TABLE `metric_screen`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `name`          varchar(50) NOT NULL COMMENT '配置名称',
    `graph_name`    varchar(50) NOT NULL DEFAULT '' COMMENT 'Graph名称',
    `view`          varchar(50) NOT NULL DEFAULT '' COMMENT '视角',
    `endPoints`     longtext    NOT NULL,
    `measurements`  longtext    NOT NULL COMMENT '配置的指标',
    `content`       longtext    NOT NULL COMMENT '配置的具体内容',
    `creation_date` datetime    NOT NULL COMMENT '配置创建时间',
    `updatetime`    datetime    NOT NULL COMMENT '配置修改时间',
    PRIMARY KEY (`id`),
    UNIQUE KEY `name_graph` (`name`, `graph_name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='系统监控的screen配置';

CREATE TABLE `metric_graph`
(
    `id`            int(11)     NOT NULL AUTO_INCREMENT,
    `graph_id`      int(11)     NOT NULL COMMENT '大盘ID',
    `name`          varchar(50) NOT NULL COMMENT '配置ID',
    `content`       longtext COMMENT '配置的具体内容',
    `creation_date` datetime    NOT NULL COMMENT '配置创建时间',
    `updatetime`    datetime    NOT NULL COMMENT '配置修改时间',
    PRIMARY KEY (`id`),
    UNIQUE `name` (`name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='系统监控的graph配置';

CREATE TABLE `server_alarm_rule`
(
    `id`            int(11)      NOT NULL AUTO_INCREMENT,
    `category`      varchar(50)  NOT NULL COMMENT '监控分类',
    `endPoint`      varchar(200) NOT NULL COMMENT '监控对象ID',
    `measurement`   varchar(200) NOT NULL COMMENT '监控指标',
    `tags`          varchar(200) NOT NULL DEFAULT '' COMMENT '监控指标标签',
    `content`       longtext     NOT NULL COMMENT '配置的具体内容',
    `type`          varchar(20)  NOT NULL DEFAULT '' COMMENT '数据聚合方式',
    `creator`       varchar(100)          DEFAULT '' COMMENT '创建人',
    `creation_date` datetime     NOT NULL COMMENT '配置创建时间',
    `updatetime`    datetime     NOT NULL COMMENT '配置修改时间',
    PRIMARY KEY (`id`),
    KEY `updatetime` (`updatetime`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8 COMMENT ='系统告警的配置';

```

</details>

### 部署 Cat
---

1. 新建 Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cat
  labels:
    kubernetes.io/metadata.name: cat
```

2. 部署 Cat Deployment，这里指定节点亲和性，保证本地存储在指定节点上

```yaml
apiVersion: apps/v1 # for versions before 1.8.0 use apps/v1beta1
kind: Deployment
metadata:
  name: cat-home
  namespace: cat
  labels:
    app: cat-home
spec:
  replicas: 2
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: cat-home
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: cat-home
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - cn-shanghai.10.20.99.10
      containers:
        - name: cat-home
          image: registry-vpc.cn-shanghai.aliyuncs.com/my_registry/cat:4.0.0
          ports:
            - containerPort: 8080
            - containerPort: 2280
          env:
            - name: MYSQL_URL
              value: "cat-mysql-service"
            - name: MYSQL_PORT
              value: "3306"
            - name: MYSQL_USERNAME
              value: "cat"
            - name: MYSQL_PASSWD
              value: "123456"
            - name: MYSQL_SCHEMA
              value: "cat"
            - name: CAT_HOME
              value: "/data/appdatas/cat"
            - name: CAT_ADMIN_PWD
              value: "123456"
          volumeMounts:
            - mountPath: /etc/localtime
              name: timezone
            - mountPath: /data/appdatas/cat/bucket
              name: storage-pv
      volumes:
        - hostPath:
            path: /etc/localtime
            type: ''
          name: timezone
        - hostPath:
            path: /data/appdatas/cat/bucket
            type: DirectoryOrCreate
          name: storage-pv
```

3. 部署 Cat Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cat-home-service
  namespace: cat
  labels:
    app: cat-home-service
spec:
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: tcp-8080-8080
    - port: 2280
      targetPort: 2280
      protocol: TCP
      name: tcp-2280-2280
  selector:
    app: cat-home
  type: ClusterIP
```

4. 部署 Cat Ingress（本地测试版）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cat-home-ingress
  namespace: cat
spec:
  ingressClassName: nginx
  rules:
    - host: cat-test.codax.cn
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cat-home-service
                port:
                  number: 8080
```

5. 域名解析（本地测试版）

在本地 hosts 文件中添加域名解析

```host
127.0.0.1 cat-test.codax.cn
```

{docsify-updated}