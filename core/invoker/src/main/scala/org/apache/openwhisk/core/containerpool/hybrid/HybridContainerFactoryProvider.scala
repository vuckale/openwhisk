package org.apache.openwhisk.core.containerpool.hybrid

import akka.actor.ActorSystem
import org.apache.openwhisk.common.{Logging, TransactionId}
import org.apache.openwhisk.core.WhiskConfig
import org.apache.openwhisk.core.containerpool.{Container, ContainerFactory, ContainerFactoryProvider}
import org.apache.openwhisk.core.containerpool.docker.{DockerApiWithFileAccess, DockerContainerFactory, ExtendedDockerClient, RuncApi, RuncClient}
import org.apache.openwhisk.core.containerpool.wasm.WasmContainerFactory
import org.apache.openwhisk.core.entity.{ByteSize, ExecManifest, InvokerInstanceId}

import scala.concurrent.{ExecutionContext, Future}

//Hybrid factory that delegates to Docker or WASM depending on the action image/kind.
class HybridContainerFactory(instance: InvokerInstanceId,
                             cfg: WhiskConfig,
                             params: Map[String, Set[String]])(implicit
    actorSystem: ActorSystem,
    ec: ExecutionContext,
    logging: Logging)
    extends ContainerFactory {

  //  implicit Docker client for DockerContainerFactory
  implicit val docker: DockerApiWithFileAccess = new ExtendedDockerClient()(ec)
  implicit val runc:   RuncApi                 = new RuncClient()(ec)

  //  delegate factories
  private val dockerFactory = new DockerContainerFactory(instance, params)
  private val wasmFactory   = new WasmContainerFactory(instance, cfg)

  override def createContainer(tid: TransactionId,
                               name: String,
                               actionImage: ExecManifest.ImageName,
                               userProvidedImage: Boolean,
                               memory: ByteSize,
                               cpuShares: Int)(implicit config: WhiskConfig, logging: Logging): Future[Container] = {

    val useWasm =
      actionImage.name.startsWith("wasm") ||
        actionImage.prefix.exists(_.toLowerCase.contains("wasm"))

    if (useWasm)
      wasmFactory.createContainer(tid, name, actionImage, userProvidedImage, memory, cpuShares)
    else
      dockerFactory.createContainer(tid, name, actionImage, userProvidedImage, memory, cpuShares)
  }

  // forward init / cleanup to both delegates
  override def init(): Unit   = { dockerFactory.init();   wasmFactory.init()   }
  override def cleanup(): Unit = { dockerFactory.cleanup(); wasmFactory.cleanup() }
}

// Provider wired via whisk.spi.ContainerFactoryProvider system property 
object HybridContainerFactoryProvider extends ContainerFactoryProvider {
  override def instance(actorSystem: ActorSystem,
                        logging: Logging,
                        config: WhiskConfig,
                        instance: InvokerInstanceId,
                        parameters: Map[String, Set[String]]): ContainerFactory =
    new HybridContainerFactory(instance, config, parameters)(actorSystem, actorSystem.dispatcher, logging)
}
