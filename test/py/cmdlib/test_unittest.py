#!/usr/bin/python
#

# Copyright (C) 2013 Google Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.


"""Tests for LUTest*"""

import mock

from ganeti import constants
from ganeti import opcodes

from testsupport import *

import testutils

DELAY_DURATION = 0.01


class TestLUTestDelay(CmdlibTestCase):
  def testRepeatedInvocation(self):
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             repeat=3)
    self.ExecOpCode(op)

    self.assertLogContainsMessage(" - INFO: Test delay iteration 0/2")
    self.mcpu.assertLogContainsEntry(constants.ELOG_MESSAGE,
                                     " - INFO: Test delay iteration 1/2")
    self.assertLogContainsRegex("2/2$")

  def testInvalidDuration(self):
    op = opcodes.OpTestDelay(duration=-1)

    self.ExecOpCodeExpectOpPrereqError(op)

  def testOnNodeUuid(self):
    node_uuids = [self.master_uuid]
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             on_node_uuids=node_uuids)
    self.ExecOpCode(op)

    self.rpc.call_test_delay.assert_called_once_with(node_uuids, DELAY_DURATION)

  def testOnNodeName(self):
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             on_nodes=[self.master.name])
    self.ExecOpCode(op)

    self.rpc.call_test_delay.assert_called_once_with([self.master_uuid],
                                                     DELAY_DURATION)

  def testSuccessfulRpc(self):
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             on_nodes=[self.master.name])

    self.rpc.call_test_delay.return_value = \
      self.RpcResultsBuilder() \
        .AddSuccessfulNode(self.master) \
        .Build()

    self.ExecOpCode(op)

    self.rpc.call_test_delay.assert_called_once()

  def testFailingRpc(self):
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             on_nodes=[self.master.name])

    self.rpc.call_test_delay.return_value = \
      self.RpcResultsBuilder() \
        .AddFailedNode(self.master) \
        .Build()

    self.ExecOpCodeExpectOpExecError(op)

  def testMultipleNodes(self):
    node1 = self.cfg.AddNewNode()
    node2 = self.cfg.AddNewNode()
    op = opcodes.OpTestDelay(duration=DELAY_DURATION,
                             on_nodes=[node1.name, node2.name],
                             on_master=False)

    self.rpc.call_test_delay.return_value = \
      self.RpcResultsBuilder() \
        .AddSuccessfulNode(node1) \
        .AddSuccessfulNode(node2) \
        .Build()

    self.ExecOpCode(op)

    self.rpc.call_test_delay.assert_called_once_with([node1.uuid, node2.uuid],
                                                     DELAY_DURATION)


class TestLUTestAllocator(CmdlibTestCase):
  def setUp(self):
    super(TestLUTestAllocator, self).setUp()

    self.base_op = opcodes.OpTestAllocator(
                      name="new-instance.example.com",
                      nics=[],
                      disks=[],
                      disk_template=constants.DT_DISKLESS,
                      direction=constants.IALLOCATOR_DIR_OUT,
                      iallocator="test")

    self.valid_alloc_op = \
      self.CopyOpCode(self.base_op,
                      mode=constants.IALLOCATOR_MODE_ALLOC,
                      memory=0,
                      disk_template=constants.DT_DISKLESS,
                      os="mock_os",
                      vcpus=1)
    self.valid_multi_alloc_op = \
      self.CopyOpCode(self.base_op,
                      mode=constants.IALLOCATOR_MODE_MULTI_ALLOC,
                      instances=["new-instance.example.com"],
                      memory=0,
                      disk_template=constants.DT_DISKLESS,
                      os="mock_os",
                      vcpus=1)
    self.valid_reloc_op = \
      self.CopyOpCode(self.base_op,
                      mode=constants.IALLOCATOR_MODE_RELOC)
    self.valid_chg_group_op = \
      self.CopyOpCode(self.base_op,
                      mode=constants.IALLOCATOR_MODE_CHG_GROUP,
                      instances=["new-instance.example.com"],
                      target_groups=["default"])
    self.valid_node_evac_op = \
      self.CopyOpCode(self.base_op,
                      mode=constants.IALLOCATOR_MODE_NODE_EVAC,
                      instances=["new-instance.example.com"],
                      evac_mode=constants.NODE_EVAC_PRI)

    self.iallocator_cls.return_value.in_text = "mock in text"
    self.iallocator_cls.return_value.out_text = "mock out text"

  def testMissingDirection(self):
    op = self.CopyOpCode(self.base_op,
                         direction=self.REMOVE)

    self.ExecOpCodeExpectOpPrereqError(
      op, "'OP_TEST_ALLOCATOR.direction' fails validation")

  def testAllocWrongDisks(self):
    op = self.CopyOpCode(self.valid_alloc_op,
                         disks=[0, "test"])

    self.ExecOpCodeExpectOpPrereqError(op, "Invalid contents")

  def testAllocWithExistingInstance(self):
    inst = self.cfg.AddNewInstance()
    op = self.CopyOpCode(self.valid_alloc_op, name=inst.name)

    self.ExecOpCodeExpectOpPrereqError(op, "already in the cluster")

  def testAllocMultiAllocMissingIAllocator(self):
    for mode in [constants.IALLOCATOR_MODE_ALLOC,
                 constants.IALLOCATOR_MODE_MULTI_ALLOC]:
      op = self.CopyOpCode(self.base_op,
                           mode=mode,
                           iallocator=None)

      self.ResetMocks()
      self.ExecOpCodeExpectOpPrereqError(op, "Missing allocator name")

  def testChgGroupNodeEvacMissingInstances(self):
    for mode in [constants.IALLOCATOR_MODE_CHG_GROUP,
                 constants.IALLOCATOR_MODE_NODE_EVAC]:
      op = self.CopyOpCode(self.base_op,
                           mode=mode)

      self.ResetMocks()
      self.ExecOpCodeExpectOpPrereqError(op, "Missing instances")

  def testAlloc(self):
    op = self.valid_alloc_op

    self.ExecOpCode(op)

    assert self.iallocator_cls.call_count == 1
    self.iallocator_cls.return_value.Run \
      .assert_called_once_with("test", validate=False)

  def testReloc(self):
    op = self.valid_reloc_op
    self.cfg.AddNewInstance(name=op.name)

    self.ExecOpCode(op)

    assert self.iallocator_cls.call_count == 1
    self.iallocator_cls.return_value.Run \
      .assert_called_once_with("test", validate=False)

  def testChgGroup(self):
    op = self.valid_chg_group_op
    for inst_name in op.instances:
      self.cfg.AddNewInstance(name=inst_name)

    self.ExecOpCode(op)

    assert self.iallocator_cls.call_count == 1
    self.iallocator_cls.return_value.Run \
      .assert_called_once_with("test", validate=False)

  def testNodeEvac(self):
    op = self.valid_node_evac_op
    for inst_name in op.instances:
      self.cfg.AddNewInstance(name=inst_name)

    self.ExecOpCode(op)

    assert self.iallocator_cls.call_count == 1
    self.iallocator_cls.return_value.Run \
      .assert_called_once_with("test", validate=False)

  def testMultiAlloc(self):
    op = self.valid_multi_alloc_op

    self.ExecOpCode(op)

    assert self.iallocator_cls.call_count == 1
    self.iallocator_cls.return_value.Run \
      .assert_called_once_with("test", validate=False)

  def testAllocDirectionIn(self):
    op = self.CopyOpCode(self.valid_alloc_op,
                         direction=constants.IALLOCATOR_DIR_IN)

    self.ExecOpCode(op)


if __name__ == "__main__":
  testutils.GanetiTestProgram()
