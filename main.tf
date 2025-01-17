locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace = coalesce(try(var.infrastructure.namespace, ""), join("-", [
    local.project_name, local.environment_name
  ]))
  gpu_vendor    = coalesce(try(var.infrastructure.gpu_vendor, ""), "nvdia.com")
  domain_suffix = coalesce(var.infrastructure.domain_suffix, "cluster.local")

  annotations = {
    "walrus.seal.io/project-id"     = local.project_id
    "walrus.seal.io/environment-id" = local.environment_id
    "walrus.seal.io/resource-id"    = local.resource_id
  }
  labels = {
    "walrus.seal.io/catalog-name"     = "terraform-kubernetes-containerservice"
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }
}

#
# Parse
#

locals {
  wellknown_env_schemas    = ["k8s:secret"]
  wellknown_file_schemas   = ["k8s:secret", "k8s:configmap"]
  wellknown_mount_schemas  = ["k8s:secret", "k8s:configmap", "k8s:persistentvolumeclaim"]
  wellknown_port_protocols = ["TCP", "UDP"]

  internal_port_container_index_map = {
    for ip, cis in merge(flatten([
      for i, c in var.containers : [{
        for p in try(c.ports != null ? c.ports : [], []) : p.internal => i...
        if p != null
      }]
    ])...) : ip => cis[0]
  }

  containers = [
    for i, c in var.containers : merge(c, {
      name = format("%s-%d-%s", coalesce(c.profile, "run"), i, basename(split(":", c.image)[0]))
      envs = [
        for xe in [
          for e in(c.envs != null ? c.envs : []) : e
          if e != null && try(!(e.value != null && e.value_refer != null) && !(e.value == null && e.value_refer == null), false)
        ] : xe
        if xe.value_refer == null || (try(contains(local.wellknown_env_schemas, xe.value_refer.schema), false) && try(lookup(xe.value_refer.params, "name", null) != null, false) && try(lookup(xe.value_refer.params, "key", null) != null, false))
      ]
      files = [
        for xf in [
          for f in(c.files != null ? c.files : []) : f
          if f != null && try(!(f.content != null && f.content_refer != null) && !(f.content == null && f.content_refer == null), false)
        ] : xf
        if xf.content_refer == null || (try(contains(local.wellknown_file_schemas, xf.content_refer.schema), false) && try(lookup(xf.content_refer.params, "name", null) != null, false) && try(lookup(xf.content_refer.params, "key", null) != null, false))
      ]
      mounts = [
        for xm in [
          for m in(c.mounts != null ? c.mounts : []) : m
          if m != null && try(!(m.volume != null && m.volume_refer != null), false)
        ] : xm
        if xm.volume_refer == null || (try(contains(local.wellknown_mount_schemas, xm.volume_refer.schema), false) && try(lookup(xm.volume_refer.params, "name", null) != null, false))
      ]
      ports = [
        for xp in [
          for _, ps in {
            for p in(c.ports != null ? c.ports : []) : p.internal => {
              internal = p.internal
              external = p.external
              protocol = p.protocol == null ? "TCP" : upper(p.protocol)
            }...
            if p != null
          } : ps[length(ps) - 1]
          if local.internal_port_container_index_map[ps[length(ps) - 1].internal] == i
        ] : xp
        if try(contains(local.wellknown_port_protocols, xp.protocol), true)
      ]
      checks = [
        for ck in(c.checks != null ? c.checks : []) : ck
        if try(lookup(ck, ck.type, null) != null, false)
      ]
    })
    if c != null
  ]
}

locals {
  container_ephemeral_envs_map = {
    for c in local.containers : c.name => [
      for e in c.envs : e
      if try(e.value_refer == null, false)
    ]
    if c != null
  }
  container_refer_envs_map = {
    for c in local.containers : c.name => [
      for e in c.envs : e
      if try(e.value_refer != null, false)
    ]
    if c != null
  }

  container_ephemeral_files_map = {
    for c in local.containers : c.name => [
      for f in c.files : merge(f, {
        name = format("eph-f-%s-%s", c.name, md5(f.path))
      })
      if try(f.content_refer == null, false)
    ]
    if c != null
  }
  container_refer_files_map = {
    for c in local.containers : c.name => [
      for f in c.files : merge(f, {
        name = format("ref-f-%s-%s", c.name, md5(jsonencode(f.content_refer)))
      })
      if try(f.content_refer != null, false)
    ]
    if c != null
  }

  container_ephemeral_mounts_map = {
    for c in local.containers : c.name => [
      for m in c.mounts : merge(m, {
        name = format("eph-m-%s", try(m.volume == null || m.volume == "", true) ? md5(join("/", [c.name, m.path])) : md5(m.volume))
      })
      if try(m.volume_refer == null, false)
    ]
    if c != null
  }
  container_refer_mounts_map = {
    for c in local.containers : c.name => [
      for m in c.mounts : merge(m, {
        name = format("ref-m-%s", md5(jsonencode(m.volume_refer)))
      })
      if try(m.volume_refer != null, false)
    ]
    if c != null
  }

  container_internal_ports_map = {
    for c in local.containers : c.name => [
      for p in c.ports : merge(p, {
        name = lower(format("%s-%d", p.protocol, p.internal))
      })
      if p != null
    ]
    if c != null
  }

  init_containers = [
    for c in local.containers : c
    if c != null && try(c.profile == "init", false)
  ]
  run_containers = [
    for c in local.containers : c
    if c != null && try(c.profile == "" || c.profile == "run", true)
  ]
}

#
# Deployment
#

## create ephemeral files.

locals {
  ephemeral_files = flatten([
    for _, fs in local.container_ephemeral_files_map : fs
  ])
  refer_files = flatten([
    for _, fs in local.container_refer_files_map : fs
  ])

  ephemeral_mounts = [
    for _, v in {
      for m in flatten([
        for _, ms in local.container_ephemeral_mounts_map : ms
      ]) : m.name => m...
    } : v[0]
  ]
  refer_mounts = [
    for _, v in {
      for m in flatten([
        for _, ms in local.container_refer_mounts_map : ms
      ]) : m.name => m...
    } : v[0]
  ]
}

locals {
  ephemeral_files_map = {
    for f in local.ephemeral_files : f.name => f
  }
}

resource "kubernetes_config_map_v1" "ephemeral_files" {
  for_each = toset(keys(try(nonsensitive(local.ephemeral_files_map), local.ephemeral_files_map)))

  metadata {
    namespace   = local.namespace
    name        = each.key
    annotations = local.annotations
    labels      = local.labels
  }

  data = {
    content = local.ephemeral_files_map[each.key].content
  }
}

## create kuberentes deployment.

locals {
  downward_annotations = {
    WALRUS_PROJECT_ID     = "walrus.seal.io/project-id"
    WALRUS_ENVIRONMENT_ID = "walrus.seal.io/environment-id"
    WALRUS_RESOURCE_ID    = "walrus.seal.io/resource-id"
  }
  downward_labels = {
    WALRUS_PROJECT_NAME     = "walrus.seal.io/project-name"
    WALRUS_ENVIRONMENT_NAME = "walrus.seal.io/environment-name"
    WALRUS_RESOURCE_NAME    = "walrus.seal.io/resource-name"
  }

  run_containers_mapping_checks_map = {
    for n, cks in {
      for c in local.run_containers : c.name => {
        startup = [
          for ck in c.checks : ck
          if try(ck.delay > 0 && ck.teardown, false)
        ]
        readiness = [
          for ck in c.checks : ck
          if try(!ck.teardown, false)
        ]
        liveness = [
          for ck in c.checks : ck
          if try(ck.teardown, false)
        ]
      }
      } : n => merge(cks, {
        startup   = try(slice(cks.startup, 0, 1), [])
        readiness = try(slice(cks.readiness, 0, 1), [])
        liveness  = try(slice(cks.liveness, 0, 1), [])
    })
  }
}

resource "kubernetes_deployment_v1" "deployment" {
  wait_for_rollout = false

  metadata {
    namespace     = local.namespace
    generate_name = format("%s-", local.resource_name)
    annotations   = local.annotations
    labels        = local.labels
  }

  spec {
    ### scaling.
    min_ready_seconds         = 0
    revision_history_limit    = 3
    progress_deadline_seconds = try(var.deployment.timeout != null && var.deployment.timeout > 0, false) ? var.deployment.timeout : null
    replicas                  = var.deployment.replicas
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = format("%d%%", try(var.deployment.rolling.max_surge, 0.25) * 100)
        max_unavailable = format("%d%%", try(var.deployment.rolling.max_unavailable, 0.25) * 100)
      }
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        annotations = local.annotations
        labels      = local.labels
      }

      spec {
        ### configure basic.
        automount_service_account_token = false
        restart_policy                  = "Always"
        dynamic "security_context" {
          for_each = try(length(var.deployment.sysctls), 0) > 0 || try(var.deployment.fs_group != null, false) ? [{}] : []
          content {
            dynamic "sysctl" {
              for_each = try(var.deployment.sysctls != null, false) ? try(
                nonsensitive(var.deployment.sysctls),
                var.deployment.sysctls
              ) : []
              content {
                name  = sysctl.value.name
                value = sysctl.value.value
              }
            }
            fs_group = try(var.deployment.fs_group, null)
          }
        }

        ### declare ephemeral files.
        dynamic "volume" {
          for_each = try(nonsensitive(local.ephemeral_files), local.ephemeral_files)
          content {
            name = volume.value.name
            config_map {
              default_mode = volume.value.mode
              name         = volume.value.name
              items {
                key  = "content"
                path = basename(volume.value.path)
              }
            }
          }
        }

        ### declare refer files.
        dynamic "volume" {
          for_each = try(nonsensitive(local.refer_files), local.refer_files)
          content {
            name = volume.value.name
            dynamic "config_map" {
              for_each = volume.value.content_refer.schema == "k8s:configmap" ? [try(nonsensitive(volume.value), volume.value)] : []
              content {
                default_mode = config_map.value.mode
                name         = config_map.value.content_refer.params.name
                items {
                  key  = config_map.value.content_refer.params.key
                  path = basename(config_map.value.path)
                }
                optional = try(lookup(config_map.value.volume_refer.params, "optional", null), null)
              }
            }
            dynamic "secret" {
              for_each = volume.value.content_refer.schema == "k8s:secret" ? [try(nonsensitive(volume.value), volume.value)] : []
              content {
                default_mode = secret.value.mode
                secret_name  = secret.value.content_refer.params.name
                items {
                  key  = secret.value.content_refer.params.key
                  path = basename(secret.value.path)
                }
                optional = try(lookup(secret.value.volume_refer.params, "optional", null), null)
              }
            }
          }
        }

        ### declare ephemeral mounts.
        dynamic "volume" {
          for_each = try(nonsensitive(local.ephemeral_mounts), local.ephemeral_mounts)
          content {
            name = volume.value.name
            empty_dir {}
          }
        }

        ### declare refer mounts.
        dynamic "volume" {
          for_each = try(nonsensitive(local.refer_mounts), local.refer_mounts)
          content {
            name = volume.value.name
            dynamic "config_map" {
              for_each = volume.value.volume_refer.schema == "k8s:configmap" ? [try(nonsensitive(volume.value), volume.value)] : []
              content {
                default_mode = try(lookup(config_map.value.volume_refer.params, "mode", null), null)
                name         = config_map.value.volume_refer.params.name
                optional     = try(lookup(config_map.value.volume_refer.params, "optional", null), null)
              }
            }
            dynamic "secret" {
              for_each = volume.value.volume_refer.schema == "k8s:secret" ? [try(nonsensitive(volume.value), volume.value)] : []
              content {
                default_mode = try(lookup(secret.value.volume_refer.params, "mode", null), null)
                secret_name  = secret.value.volume_refer.params.name
                optional     = try(lookup(secret.value.volume_refer.params, "optional", null), null)
              }
            }
            dynamic "persistent_volume_claim" {
              for_each = volume.value.volume_refer.schema == "k8s:persistentvolumeclaim" ? [try(nonsensitive(volume.value), volume.value)] : []
              content {
                read_only  = try(lookup(persistent_volume_claim.value.volume_refer.params, "readonly", null), false)
                claim_name = persistent_volume_claim.value.volume_refer.params.name
              }
            }
          }
        }

        ### configure init containers.
        dynamic "init_container" {
          for_each = try(nonsensitive(local.init_containers), local.init_containers)
          content {
            #### configure basic.
            name              = init_container.value.name
            image             = init_container.value.image
            image_pull_policy = "IfNotPresent"
            working_dir       = try(init_container.value.execute.working_dir, null)
            command           = try(init_container.value.execute.command, null)
            args              = try(init_container.value.execute.args, null)
            security_context {
              read_only_root_filesystem = try(init_container.value.execute.readonly_rootfs, false)
              run_as_user               = try(init_container.value.execute.as_user, null)
              run_as_group              = try(init_container.value.execute.as_group, null)
            }

            #### configure resources.
            dynamic "resources" {
              for_each = init_container.value.resources != null ? try(
                [nonsensitive(init_container.value.resources)],
                [init_container.value.resources]
              ) : []
              content {
                requests = {
                  for k, v in resources.value : "%{if k == "gpu"}${local.gpu_vendor}/%{endif}${k}" => "%{if k == "memory"}${v}Mi%{else}${v}%{endif}"
                  if try(v != null && v > 0, false)
                }
                limits = {
                  for k, v in resources.value : "%{if k == "gpu"}${local.gpu_vendor}/%{endif}${k}" => "%{if k == "memory"}${v}Mi%{else}${v}%{endif}"
                  if try(v != null && v > 0, false) && k != "cpu"
                }
              }
            }

            #### configure ephemeral envs.
            dynamic "env" {
              for_each = local.container_ephemeral_envs_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_envs_map[init_container.value.name]),
                local.container_ephemeral_envs_map[init_container.value.name]
              ) : []
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            #### configure refer envs.
            dynamic "env" {
              for_each = local.container_refer_envs_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_refer_envs_map[init_container.value.name]),
                local.container_refer_envs_map[init_container.value.name]
              ) : []
              content {
                name = env.value.name
                value_from {
                  secret_key_ref {
                    name = env.value.value_refer.params.name
                    key  = env.value.value_refer.params.key
                  }
                }
              }
            }

            #### configure downward-api envs.
            dynamic "env" {
              for_each = local.downward_annotations
              content {
                name = env.key
                value_from {
                  field_ref {
                    field_path = format("metadata.annotations['%s']", env.value)
                  }
                }
              }
            }
            dynamic "env" {
              for_each = local.downward_labels
              content {
                name = env.key
                value_from {
                  field_ref {
                    field_path = format("metadata.labels['%s']", env.value)
                  }
                }
              }
            }

            #### configure ephemeral files.
            dynamic "volume_mount" {
              for_each = local.container_ephemeral_files_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_files_map[init_container.value.name]),
                local.container_ephemeral_files_map[init_container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = try(volume_mount.value.accept_changed, false) ? dirname(volume_mount.value.path) : volume_mount.value.path
                sub_path   = try(volume_mount.value.accept_changed, false) ? null : basename(volume_mount.value.path)
              }
            }

            #### configure refer files.
            dynamic "volume_mount" {
              for_each = local.container_refer_files_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_refer_files_map[init_container.value.name]),
                local.container_refer_files_map[init_container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = try(volume_mount.value.accept_changed, false) ? dirname(volume_mount.value.path) : volume_mount.value.path
                sub_path   = try(volume_mount.value.accept_changed, false) ? null : basename(volume_mount.value.path)
              }
            }

            #### configure ephemeral mounts.
            dynamic "volume_mount" {
              for_each = local.container_ephemeral_mounts_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_mounts_map[init_container.value.name]),
                local.container_ephemeral_mounts_map[init_container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.path
                read_only  = try(volume_mount.value.readonly, null)
                sub_path   = try(volume_mount.value.subpath, null)
              }
            }

            #### configure refer mounts.
            dynamic "volume_mount" {
              for_each = local.container_refer_mounts_map[init_container.value.name] != null ? try(
                nonsensitive(local.container_refer_mounts_map[init_container.value.name]),
                local.container_refer_mounts_map[init_container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.path
                read_only  = try(volume_mount.value.readonly, null)
                sub_path   = try(volume_mount.value.subpath, null)
              }
            }
          }
        }

        ### configure run containers.
        dynamic "container" {
          for_each = try(nonsensitive(local.run_containers), local.run_containers)
          content {
            #### configure basic.
            name              = container.value.name
            image             = container.value.image
            image_pull_policy = "IfNotPresent"
            working_dir       = try(container.value.execute.working_dir, null)
            command           = try(container.value.execute.command, null)
            args              = try(container.value.execute.args, null)
            security_context {
              read_only_root_filesystem = try(container.value.execute.readonly_rootfs, false)
              run_as_user               = try(container.value.execute.as_user, null)
              run_as_group              = try(container.value.execute.as_group, null)
            }

            #### configure resources.
            dynamic "resources" {
              for_each = container.value.resources != null ? try(
                [nonsensitive(container.value.resources)],
                [container.value.resources]
              ) : []
              content {
                requests = {
                  for k, v in resources.value : "%{if k == "gpu"}${local.gpu_vendor}/%{endif}${k}" => "%{if k == "memory"}${v}Mi%{else}${v}%{endif}"
                  if try(v != null && v > 0, false)
                }
                limits = {
                  for k, v in resources.value : "%{if k == "gpu"}${local.gpu_vendor}/%{endif}${k}" => "%{if k == "memory"}${v}Mi%{else}${v}%{endif}"
                  if try(v != null && v > 0, false) && k != "cpu"
                }
              }
            }

            #### configure ephemeral envs.
            dynamic "env" {
              for_each = local.container_ephemeral_envs_map[container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_envs_map[container.value.name]),
                local.container_ephemeral_envs_map[container.value.name]
              ) : []
              content {
                name  = env.value.name
                value = env.value.value
              }
            }

            #### configure refer envs.
            dynamic "env" {
              for_each = local.container_refer_envs_map[container.value.name] != null ? try(
                nonsensitive(local.container_refer_envs_map[container.value.name]),
                local.container_refer_envs_map[container.value.name]
              ) : []
              content {
                name = env.value.name
                value_from {
                  secret_key_ref {
                    name = env.value.value_refer.params.name
                    key  = env.value.value_refer.params.key
                  }
                }
              }
            }

            #### configure downward-api envs.
            dynamic "env" {
              for_each = local.downward_annotations
              content {
                name = env.key
                value_from {
                  field_ref {
                    field_path = format("metadata.annotations['%s']", env.value)
                  }
                }
              }
            }
            dynamic "env" {
              for_each = local.downward_labels
              content {
                name = env.key
                value_from {
                  field_ref {
                    field_path = format("metadata.labels['%s']", env.value)
                  }
                }
              }
            }

            #### configure ephemeral files.
            dynamic "volume_mount" {
              for_each = local.container_ephemeral_files_map[container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_files_map[container.value.name]),
                local.container_ephemeral_files_map[container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = try(volume_mount.value.accept_changed, false) ? dirname(volume_mount.value.path) : volume_mount.value.path
                sub_path   = try(volume_mount.value.accept_changed, false) ? null : basename(volume_mount.value.path)
              }
            }

            #### configure refer files.
            dynamic "volume_mount" {
              for_each = local.container_refer_files_map[container.value.name] != null ? try(
                nonsensitive(local.container_refer_files_map[container.value.name]),
                local.container_refer_files_map[container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = try(volume_mount.value.accept_changed, false) ? dirname(volume_mount.value.path) : volume_mount.value.path
                sub_path   = try(volume_mount.value.accept_changed, false) ? null : basename(volume_mount.value.path)
              }
            }

            #### configure ephemeral mounts.
            dynamic "volume_mount" {
              for_each = local.container_ephemeral_mounts_map[container.value.name] != null ? try(
                nonsensitive(local.container_ephemeral_mounts_map[container.value.name]),
                local.container_ephemeral_mounts_map[container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.path
                read_only  = try(volume_mount.value.readonly, null)
                sub_path   = try(volume_mount.value.subpath, null)
              }
            }

            #### configure refer mounts.
            dynamic "volume_mount" {
              for_each = local.container_refer_mounts_map[container.value.name] != null ? try(
                nonsensitive(local.container_refer_mounts_map[container.value.name]),
                local.container_refer_mounts_map[container.value.name]
              ) : []
              content {
                name       = volume_mount.value.name
                mount_path = volume_mount.value.path
                read_only  = try(volume_mount.value.readonly, null)
                sub_path   = try(volume_mount.value.subpath, null)
              }
            }

            #### configure internal ports.
            dynamic "port" {
              for_each = local.container_internal_ports_map[container.value.name] != null ? try(
                nonsensitive(local.container_internal_ports_map[container.value.name]),
                local.container_internal_ports_map[container.value.name]
              ) : []
              content {
                name           = port.value.name
                protocol       = port.value.protocol
                container_port = port.value.internal
              }
            }

            #### configure checks.
            dynamic "startup_probe" {
              for_each = try(
                nonsensitive(local.run_containers_mapping_checks_map[container.value.name].startup),
                local.run_containers_mapping_checks_map[container.value.name].startup
              )
              content {
                initial_delay_seconds = startup_probe.value.delay
                period_seconds        = startup_probe.value.interval
                timeout_seconds       = startup_probe.value.timeout
                failure_threshold     = startup_probe.value.retries
                dynamic "exec" {
                  for_each = startup_probe.value.type == "execute" ? [
                    try(nonsensitive(startup_probe.value.execute), startup_probe.value.execute)
                  ] : []
                  content {
                    command = exec.value.command
                  }
                }
                dynamic "tcp_socket" {
                  for_each = startup_probe.value.type == "tcp" ? [
                    try(nonsensitive(startup_probe.value.tcp), startup_probe.value.tcp)
                  ] : []
                  content {
                    port = tcp_socket.value.port
                  }
                }
                dynamic "http_get" {
                  for_each = startup_probe.value.type == "http" ? [
                    try(nonsensitive(startup_probe.value.http), startup_probe.value.http)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTP"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
                dynamic "http_get" {
                  for_each = startup_probe.value.type == "https" ? [
                    try(nonsensitive(startup_probe.value.https), startup_probe.value.https)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTPS"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
              }
            }

            dynamic "readiness_probe" {
              for_each = try(
                nonsensitive(local.run_containers_mapping_checks_map[container.value.name].readiness),
                local.run_containers_mapping_checks_map[container.value.name].readiness
              )
              content {
                initial_delay_seconds = readiness_probe.value.delay
                period_seconds        = readiness_probe.value.interval
                timeout_seconds       = readiness_probe.value.timeout
                failure_threshold     = readiness_probe.value.retries
                dynamic "exec" {
                  for_each = readiness_probe.value.type == "execute" ? [
                    try(nonsensitive(readiness_probe.value.execute), readiness_probe.value.execute)
                  ] : []
                  content {
                    command = exec.value.command
                  }
                }
                dynamic "tcp_socket" {
                  for_each = readiness_probe.value.type == "tcp" ? [
                    try(nonsensitive(readiness_probe.value.tcp), readiness_probe.value.tcp)
                  ] : []
                  content {
                    port = tcp_socket.value.port
                  }
                }
                dynamic "http_get" {
                  for_each = readiness_probe.value.type == "http" ? [
                    try(nonsensitive(readiness_probe.value.http), readiness_probe.value.http)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTP"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
                dynamic "http_get" {
                  for_each = readiness_probe.value.type == "https" ? [
                    try(nonsensitive(readiness_probe.value.https), readiness_probe.value.https)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTPS"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
              }
            }

            dynamic "liveness_probe" {
              for_each = try(
                nonsensitive(local.run_containers_mapping_checks_map[container.value.name].liveness),
                local.run_containers_mapping_checks_map[container.value.name].liveness
              )
              content {
                period_seconds    = liveness_probe.value.interval
                timeout_seconds   = liveness_probe.value.timeout
                failure_threshold = liveness_probe.value.retries
                dynamic "exec" {
                  for_each = liveness_probe.value.type == "execute" ? [
                    try(nonsensitive(liveness_probe.value.execute), liveness_probe.value.execute)
                  ] : []
                  content {
                    command = exec.value.command
                  }
                }
                dynamic "tcp_socket" {
                  for_each = liveness_probe.value.type == "tcp" ? [
                    try(nonsensitive(liveness_probe.value.tcp), liveness_probe.value.tcp)
                  ] : []
                  content {
                    port = tcp_socket.value.port
                  }
                }
                dynamic "http_get" {
                  for_each = liveness_probe.value.type == "http" ? [
                    try(nonsensitive(liveness_probe.value.http), liveness_probe.value.http)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTP"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
                dynamic "http_get" {
                  for_each = liveness_probe.value.type == "https" ? [
                    try(nonsensitive(liveness_probe.value.https), liveness_probe.value.https)
                  ] : []
                  content {
                    port   = http_get.value.port
                    path   = http_get.value.path
                    scheme = "HTTPS"
                    dynamic "http_header" {
                      for_each = try(http_get.value.headers != null, false) ? try(nonsensitive(http_get.value.headers), http_get.value.headers) : {}
                      content {
                        name  = http_header.key
                        value = http_header.value
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

#
# Exposing
#

locals {
  external_ports = flatten([
    for c in local.containers : [
      for p in c.ports : p
      if try(p.external != null, false)
    ]
    if c != null
  ])
}

resource "terraform_data" "replacement" {
  input = sha256(jsonencode({
    has_external_ports = length(try(nonsensitive(local.external_ports), local.external_ports)) > 0
  }))
}

resource "kubernetes_service_v1" "service" {
  wait_for_load_balancer = false

  metadata {
    namespace   = local.namespace
    name        = local.resource_name
    annotations = local.annotations
    labels      = local.labels
  }

  spec {
    selector         = local.labels
    type             = length(local.external_ports) > 0 ? try(coalesce(var.infrastructure.service_type, "NodePort"), "NodePort") : "ClusterIP"
    session_affinity = length(local.external_ports) > 0 ? "ClientIP" : "None"
    cluster_ip       = length(local.external_ports) > 0 ? null : "None"

    dynamic "port" {
      for_each = try(nonsensitive(local.external_ports), local.external_ports)
      content {
        name        = lower(format("%s-%d", port.value.protocol, port.value.external))
        target_port = port.value.internal
        port        = port.value.external
        protocol    = port.value.protocol
      }
    }
  }

  lifecycle {
    replace_triggered_by = [terraform_data.replacement]
  }
}
