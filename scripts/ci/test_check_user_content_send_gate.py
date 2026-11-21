#!/usr/bin/env python3
"""Self-test of check_user_content_send_gate.py: fixtures that must pass and fixtures that must fail."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gate", os.path.join(HERE, "check_user_content_send_gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def problems(source, path="QAudionApp/Views/Other.swift"):
    return gate.check_source(path, source)


# A send without the token or a reason fails.
check(problems("let o = await s.sendEncrypted(messageId: id, peerUserId: p, plaintext: t)\n"), "bare send must fail")
check(problems("let o = await s.sendEncryptedDurable(\n messageId: id,\n conversationId: c,\n peerUserId: p,\n plaintext: t)\n"),
      "bare durable send must fail")
# With the token it passes, also when the argument is on a later line.
check(not problems("let o = await s.sendEncryptedDurable(\n messageId: id, peerUserId: p, plaintext: t,\n userChoice: choice)\n"),
      "send with the token must pass")
# Service class passes.
check(not problems("let o = await s.sendEncrypted(messageId: id, peerUserId: p, plaintext: t, payloadClass: .service)\n"),
      "service class must pass")
# A reason passes.
check(not problems("// gate-exempt: held before this\nlet o = await s.sendEncrypted(messageId: id, peerUserId: p, plaintext: t)\n"),
      "marked send must pass")
# A declaration is not a call.
check(not problems("    func sendEncrypted(\n        messageId: UUID\n    ) async -> Outcome {\n"), "declaration must pass")
# A direct sendMessage needs the approval check or a reason.
check(problems("_ = try await live.messageApi.sendMessage(recipientId: p, content: b, clientMsgId: c)\n"), "bare sendMessage must fail")
check(not problems("if !UserNetworkApprovalStore.shared.isApproved(messageId: c) { throw X }\n_ = try await live.messageApi.sendMessage(recipientId: p)\n"),
      "approved sendMessage must pass")
# The token is created only in the tap handler file.
check(problems("let c = UserNetworkChoice.tapped(messageId: id)\n"), "token outside the tap handlers must fail")
check(not problems("let c = UserNetworkChoice.tapped(messageId: id)\n", "QAudionApp/Views/ChatContainer.swift"),
      "token in the tap handler file must pass")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    sys.exit(1)
print("OK: %d checks" % 10)
