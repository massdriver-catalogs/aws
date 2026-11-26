resource "massdriver_resource" "destination" {
  for_each = massdriver_event_destination.main

  field = replace(each.key, "-", "_")
  name  = each.value.name
  resource = jsonencode(merge(
    {
      id             = each.value.id
      name           = each.value.name
      url            = jsondecode(each.value.config).url
      signing_secret = each.value.signing_secret
      event_types    = coalesce(each.value.event_types, [])
      attributes     = coalesce(each.value.attributes, {})
    },
    each.value.condition == null ? {} : { condition = each.value.condition },
  ))
}
