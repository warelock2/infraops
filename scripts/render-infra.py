#!/usr/bin/env python3
"""
Generate draw.io architecture diagrams from infrastructure.yaml.

Usage:
  python scripts/render-infra.py                                # Full diagram
  yq '.clusters[] | select(.name == "mushroom")' infrastructure.yaml | python scripts/render-infra.py
"""
import sys
import subprocess
import yaml
from pathlib import Path
from xml.sax.saxutils import escape

BASE = Path(__file__).resolve().parent.parent
INFRA_PATH = BASE / "conf" / "infrastructure.yaml"

PADDING = 30
NODE_W = 140
NODE_H = 70
CLUSTER_MIN_W = 500
CLUSTER_PAD = 20

SERVICE_ICONS = {
    "docker_compose": "mxgraph.docker.compose_service",
    "helm":           "mxgraph.kubernetes.helm",
    "systemd":        "mxgraph.gcp2.generic_service",
    "nomad_job":      "mxgraph.gcp2.generic_service",
    "ecs_service":    "mxgraph.aws4.ecs_service",
}


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def resolve_data(infra, expr):
    if not expr:
        return infra
    r = subprocess.run(
        ["yq", "-o=yaml", expr, str(INFRA_PATH)],
        capture_output=True, text=True, check=True,
    )
    return yaml.safe_load(r.stdout)


def flatten_instances(instances):
    if isinstance(instances, list):
        return instances
    if isinstance(instances, dict):
        result = []
        for type_key, svc_list in instances.items():
            if isinstance(svc_list, list):
                for svc in svc_list:
                    svc.setdefault("service_type", type_key)
                result.extend(svc_list)
        return result
    return []


def determine_shape(data):
    if isinstance(data, list):
        if not data:
            return [], "empty"
        s = data[0]
        if isinstance(s, dict):
            if "control_plane" in s and "workers" in s:
                return data, "clusters"
            if "name" in s and "port" in s:
                return data, "services"
    if isinstance(data, dict):
        if "control_plane" in data and "workers" in data:
            return [data], "clusters"
        if "clusters" in data:
            return data["clusters"], "clusters"
        if "services" in data and "instances" in data["services"]:
            return flatten_instances(data["services"]["instances"]), "services"
    return data, "unknown"


def cluster_type_of(cluster, infra):
    return cluster.get("cluster_type") or infra.get("defaults", {}).get("cluster_type", "k8s")


def plane_name_of(cluster, plane_key, infra):
    return (
        cluster.get("plane_defaults", {}).get(plane_key, {}).get("plane_name")
        or infra.get("defaults", {}).get("planes", {}).get(plane_key, {}).get("plane_name", plane_key)
    )


def expand_nodes(cluster, plane_key, infra):
    plane = cluster.get(plane_key, {})
    count = plane.get("nodes", 0)
    start = plane.get("vm_id_start")
    ct = cluster_type_of(cluster, infra)
    pn = plane_name_of(cluster, plane_key, infra)
    for n in range(count):
        name = f"{ct}-{cluster['name']}-{pn}-{n + 1:02d}"
        yield {
            "name": name,
            "vm_id": (start + n) if start is not None else None,
            "memory_gb": plane.get("memory_gb"),
            "cores": plane.get("cores"),
            "disk_gb": plane.get("disk_gb"),
            "datastore": plane.get("datastore"),
        }


def node_icon(cluster, plane_key):
    return (
        cluster.get(plane_key, {}).get("drawio_icon")
        or cluster.get("plane_defaults", {}).get(plane_key, {}).get("drawio_icon")
    )


def service_icon(svc, infra):
    icon = svc.get("drawio_icon")
    if icon:
        return icon
    st = svc.get("service_type") or infra.get("defaults", {}).get("service_type")
    return SERVICE_ICONS.get(st, "mxgraph.gcp2.generic_service")


class Builder:
    def __init__(self, infra):
        self.infra = infra
        self.cells = []
        self.nid = 2
        self.x_off = 50
        self.y_off = 50

    def _id(self):
        i = self.nid
        self.nid += 1
        return str(i)

    def cell(self, label, icon, x, y, w, h, parent="1", container=0):
        cid = self._id()
        parts = [
            f"shape={icon}", "whiteSpace=wrap", "html=1",
            "overflow=fill", "fontSize=12", "align=center",
            "verticalAlign=middle", "rounded=1",
        ]
        if container:
            parts += ["container=1", "collapsible=1", "recursiveResize=0"]
        style = ";".join(parts)
        self.cells.append(
            f'  <mxCell id="{cid}" value="{escape(label)}" '
            f'vertex="1" parent="{parent}" style="{style}">\n'
            f'    <mxGeometry x="{x}" y="{y}" width="{w}" '
            f'height="{h}" as="geometry" />\n'
            f"  </mxCell>"
        )
        return cid

    def separator(self, label, x, y, w):
        cid = self._id()
        self.cells.append(
            f'  <mxCell id="{cid}" value="{escape(label)}" '
            f'vertex="1" parent="1" style="text;html=1;'
            f'align=left;verticalAlign=middle;fontSize=14;'
            f'fontStyle=4;strokeColor=none;fillColor=none;">\n'
            f'    <mxGeometry x="{x}" y="{y}" width="{w}" '
            f'height="24" as="geometry" />\n'
            f"  </mxCell>"
        )

    def render_clusters(self, clusters):
        y = self.y_off
        for cluster in clusters:
            name = cluster["name"]
            ct = cluster_type_of(cluster, self.infra)
            cicon = cluster.get("drawio_icon") or "mxgraph.kubernetes.kubernetes_cluster"

            nodes = []
            for plane_key in ("control_plane", "workers"):
                for n in expand_nodes(cluster, plane_key, self.infra):
                    nodes.append((plane_key, n))

            if not nodes:
                continue

            total_w = max(len(nodes) * (NODE_W + PADDING) - PADDING, CLUSTER_MIN_W)
            ch = 50 + NODE_H + 20

            parent_id = self.cell(
                f"{ct} Cluster: {name}",
                cicon,
                self.x_off, y, total_w + CLUSTER_PAD * 2, ch,
                container=1,
            )

            nx = self.x_off + CLUSTER_PAD
            ny = y + 40
            for plane_key, node in nodes:
                ni = node_icon(cluster, plane_key) or "mxgraph.kubernetes.node"
                label = node["name"]
                extra = []
                if node.get("vm_id"):
                    extra.append(f"VM: {node['vm_id']}")
                if node.get("memory_gb"):
                    extra.append(f"{node['memory_gb']}GB")
                if extra:
                    label += f"\n({' | '.join(extra)})"
                self.cell(label, ni, nx, ny, NODE_W, NODE_H, parent=parent_id)
                nx += NODE_W + PADDING

            y += ch + PADDING * 2

        return y

    def render_services(self, services, start_y):
        if not services:
            return start_y

        y = start_y
        self.separator("Services", self.x_off, y, 400)
        y += 30

        sx = self.x_off
        svc_w = 180
        svc_h = 70
        for svc in services:
            icon = service_icon(svc, self.infra)
            host = self.infra.get("services", {}).get("defaults", {}).get("host", "unknown")
            subtitle = f"{host}:{svc.get('port', '')}"
            self.cell(f"{svc['name']}\n({subtitle})", icon, sx, y, svc_w, svc_h)
            sx += svc_w + PADDING

        return y + svc_h + PADDING

    def build(self):
        cells_xml = "\n".join(self.cells)
        return f"""<mxfile>
  <diagram id="infraops" name="Infrastructure">
    <mxGraphModel dx="0" dy="0" grid="1" gridSize="10"
        guides="1" tooltips="1" connect="1" arrows="1"
        fold="1" page="1" pageScale="1"
        pageWidth="1169" pageHeight="827">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
{cells_xml}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>"""


def main():
    expr = sys.argv[1] if len(sys.argv) > 1 else ""
    infra = load_yaml(INFRA_PATH)
    data = resolve_data(infra, expr)
    items, kind = determine_shape(data)

    if kind == "unknown":
        print(f"Unable to determine diagram type. Received: {type(data).__name__}")
        sys.exit(1)

    builder = Builder(infra)
    if kind == "clusters":
        end_y = builder.render_clusters(items)
        if not expr:
            services = flatten_instances(infra.get("services", {}).get("instances", {}))
            builder.render_services(services, end_y)
    elif kind == "services":
        builder.render_services(items, builder.y_off)

    out = BASE / "infra.drawio"
    with open(out, "w") as f:
        f.write(builder.build())
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
