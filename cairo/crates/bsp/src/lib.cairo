// SPDX-License-Identifier: Apache-2.0

use geom2d::{Point, point_on_side};

#[derive(Copy, Drop, Serde)]
pub enum Child {
    NodeIndex: u32,
    Subsector: u32,
}

#[derive(Copy, Drop, Serde)]
pub struct Node {
    pub a: Point,
    pub b: Point,
    pub front: Child,
    pub back: Child,
}

/// Walk the BSP tree starting at `root`, returning the id of the subsector
/// that contains `p`. Panics if the tree is malformed (more hops than
/// nodes, meaning a cycle or an out-of-range index).
pub fn point_in_subsector(nodes: Span<Node>, root: u32, p: Point) -> u32 {
    let mut current = root;
    let mut steps: u32 = 0;
    let max_steps: u32 = nodes.len() + 1;
    loop {
        assert(steps < max_steps, 'bsp: cycle or oob');
        steps += 1;
        let node = *nodes.at(current);
        let side = point_on_side(p, node.a, node.b);
        let child = if side >= 0 {
            node.front
        } else {
            node.back
        };
        match child {
            Child::NodeIndex(idx) => { current = idx; },
            Child::Subsector(id) => { break id; },
        }
    }
}

#[cfg(test)]
mod tests {
    use fixed::from_int;
    use geom2d::Point;
    use super::{Child, Node, point_in_subsector};

    fn pt(x: i64, y: i64) -> Point {
        Point { x: from_int(x), y: from_int(y) }
    }

    /// Two-node tree: first split on the vertical line x=0 (left of it is
    /// directly subsector 2; right of it descends into node 1), then node 1
    /// splits the right side on the horizontal line y=0 (top: subsector 0,
    /// bottom: subsector 1).
    fn sample_tree() -> Array<Node> {
        let mut nodes = array![];
        nodes
            .append(
                Node {
                    a: pt(0, -10),
                    b: pt(0, 10),
                    front: Child::Subsector(2),
                    back: Child::NodeIndex(1),
                },
            );
        nodes
            .append(
                Node {
                    a: pt(-10, 0),
                    b: pt(10, 0),
                    front: Child::Subsector(0),
                    back: Child::Subsector(1),
                },
            );
        nodes
    }

    #[test]
    fn test_point_in_subsector_left_side() {
        let nodes = sample_tree();
        let id = point_in_subsector(nodes.span(), 0, pt(-5, 5));
        assert(id == 2, 'left side is subsector 2');
    }

    #[test]
    fn test_point_in_subsector_right_top() {
        let nodes = sample_tree();
        let id = point_in_subsector(nodes.span(), 0, pt(5, 5));
        assert(id == 0, 'right/top is subsector 0');
    }

    #[test]
    fn test_point_in_subsector_right_bottom() {
        let nodes = sample_tree();
        let id = point_in_subsector(nodes.span(), 0, pt(5, -5));
        assert(id == 1, 'right/bottom is subsector 1');
    }

    #[test]
    #[should_panic(expected: 'bsp: cycle or oob')]
    fn test_cyclic_tree_panics_instead_of_looping() {
        let mut nodes = array![];
        // A node whose both children point back to node 0: a cycle.
        nodes
            .append(
                Node {
                    a: pt(0, -10),
                    b: pt(0, 10),
                    front: Child::NodeIndex(0),
                    back: Child::NodeIndex(0),
                },
            );
        point_in_subsector(nodes.span(), 0, pt(5, 5));
    }
}
