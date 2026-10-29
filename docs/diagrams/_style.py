"""Shared styling for the architecture diagrams (loaded by path, so the
scripts also work with `python -I`)."""
import diagrams
from diagrams import Diagram, Edge

# diagrams sizes each node from its label's line count (explicit `height` is
# overridden). A leading blank line buys one line of space between icon and
# label, so larger fonts no longer overlap the icon.
_node_init = diagrams.Node.__init__
def _padded_init(self, label="", *args, **kwargs):
    pad = "\n" * (label.count("\n") + 1)   # multi-line labels need proportionally more room
    _node_init(self, pad + label if label else label, *args, **kwargs)
diagrams.Node.__init__ = _padded_init

# Large, high-contrast styling: readable in GitHub light and dark mode.
# Curved splines keep edge labels on their edges (orthogonal routing scatters them).
GRAPH = {"fontsize": "40", "fontname": "Helvetica Bold", "bgcolor": "white", "pad": "0.6",
         "nodesep": "1.0", "ranksep": "1.4", "dpi": "110", "labelloc": "t", "splines": "spline"}
NODE = {"fontsize": "22", "fontname": "Helvetica", "fontcolor": "#16191f"}
EDGE = {"fontsize": "24", "fontname": "Helvetica Bold", "fontcolor": "#16191f", "penwidth": "2.6", "color": "#3b4a5a"}
CLUSTER = lambda bg, border: {"fontsize": "28", "fontname": "Helvetica Bold", "bgcolor": bg,
                              "pencolor": border, "penwidth": "2.5", "margin": "24", "style": "rounded"}

AWS_CLOUD = CLUSTER("#f7f9fa", "#232f3e")
REGION = CLUSTER("#ffffff", "#147eba")
VPC_STYLE = CLUSTER("#f2f8ea", "#7aa116")
PUBLIC = CLUSTER("#e9f3e6", "#7aa116")
PRIVATE = CLUSTER("#e6f2f8", "#147eba")
EKS_STYLE = CLUSTER("#fdf1e6", "#ed7100")
NEUTRAL = CLUSTER("#f4f4f4", "#8c8c8c")
GITHUB = CLUSTER("#f6f8fa", "#24292f")

FLOW = lambda label, color="#3b4a5a", style="solid": Edge(
    label=f"  {label}  " if label else "", color=color, fontcolor=color, style=style, penwidth="3",
    fontsize="24", fontname="Helvetica Bold")
ORANGE, BLUE, GREEN, RED, PURPLE = "#d45b07", "#147eba", "#3f8624", "#c7131f", "#7b3fbf"


def diagram(out, name, title, direction="LR", graph=None, node=None):
    return Diagram(title, filename=str(out / name), outformat="png", show=False, direction=direction,
                   graph_attr={**GRAPH, **(graph or {})}, node_attr={**NODE, **(node or {})}, edge_attr=EDGE)


