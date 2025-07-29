### 准备客户端 jar
---

最新客户端代码打包并上传到 Maven 私服，注意需要修改 cat-client pom 指定版本号 <version>4.0.0</version>

```bash
mvn clean deploy -DskipTests
```

### 项目集成
---

1. 项目添加 Maven 依赖

```xml

<dependency>
    <groupId>com.dianping.cat</groupId>
    <artifactId>cat-client</artifactId>
    <version>4.0.0</version>
</dependency>
```

2. 项目新建文件 src/main/resources/META-INF/app.properties, 在其中配置项目名：`app.name=项目名`

3. 项目部署文件 Deployment.yaml 中添加客户端配置文件 /root/.cat/client.xml 映射，指向 ConfigMap 中的 client.xml

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  spec:
    containers:
      - volumeMounts:
          - mountPath: /root/.cat/client.xml
            name: client-pv
            subPath: client.xml
    volumes:
      - name: client-pv
        configMap:
          name: cat-client-config
```

### 部署项目
---

1. 在项目命名空间 test 中新建 ConfigMap 客户端配置 client.xml，注意这里的 ip 指向命名空间 cat 中的服务

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cat-client-config
  namespace: test
data:
  client.xml: |-
    <?xml version="1.0" encoding="utf-8"?>
    <config mode="client">
        <servers>
            <server ip="cat-home-service.cat.svc.cluster.local" port="2280" http-port="8080"/>
        </servers>
    </config>

```

2. 部署项目 Deployment.yaml

### 打点验证
---
本地开发调试时，需要将 client.xml 文件复制到默认的工作目录 ~/.cat 下，并修改其中的 ip 为开发环境可访问的 IP 地址。

注意使用单元测试验证时，要设置延迟等待监控数据异步上报完成。

```java

@Test
public void test() throws Exception {
    Transaction t = Cat.newTransaction("/test", "test-page");

    try {
        Cat.logEvent("aaa", "bbb", Event.SUCCESS, "ip=${serverIp}");
        Cat.logMetricForCount("ccc");
        Cat.logMetricForDuration("ddd", 5);

        // 模拟业务
        Thread.sleep(2700);

        t.setStatus(Transaction.SUCCESS);

        int i = 1 / 0;
    } catch (Exception e) {
        t.setStatus(e);
        Cat.logError(e);
    } finally {
        t.complete();
    }

    // 保证异步处理完成
    Thread.sleep(5 * 60 * 1000);
}
```

{docsify-updated}