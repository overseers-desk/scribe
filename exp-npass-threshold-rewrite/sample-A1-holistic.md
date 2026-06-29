---
title: "Our Story"
description: "How a season of jacaranda blossoms, a 5G ban, and a backdoor that nearly broke the internet led to opensource.foundation"
draft: false
---

## The jacarandas were blooming

It was October 2018. I was drinking coffee at Coomera River, in a cafe called Historic Rivermill. The trees were in full bloom. The whole bank had turned violet; blossoms fell so thick they covered the footpaths. The air was warm, the light long, everything pointing to change.

That spring, something else was shifting. Two months earlier, Australia had become the first country to ban Huawei equipment from its 5G networks. The Telecommunications Sector Security Reforms had passed, and the government's judgement was blunt: no set of technical controls could reduce the risks posed by vendors answerable to a foreign government's orders.

I was talking with engineers and managers from Huawei at the time, and with contractors who had installed their systems. Many felt they were being wronged. Their argument rested on open source: Huawei's systems drew heavily on open source parts, and the company put real work into contributing upstream. The code was open. Anyone could read it. Was that not the whole point?

But when I pressed, even the most sure among them admitted something awkward. None of them could say whether they were *truly* clear of blame. Their internal version control did not track every fork. When a part was changed for a carrier deployment, it was hard to tell whether the shipped version still matched the checked open source codebase. The code might be open, but the chain from open source repository to deployed system was not fully visible.

I asked myself a question that stayed with me: *Is this passing? Will trust return once the politics cool down?*

## It didn't come back

In May 2019, the United States placed Huawei and 68 affiliates on the Entity List, requiring a government licence for any American company to sell technology to them. In 2020, the Foreign Direct Product Rule was tightened to cut Huawei off from advanced chip manufacturing, even at overseas foundries that used American equipment. What had started as one country's security judgement became a worldwide split.

And it was not just China.

In 2019, GitHub, the platform where most of the world's open source lives, began blocking accounts in Iran, Syria, Crimea, and Cuba to comply with US sanctions. Developers who had given to open source for years found their private repositories locked overnight, not for anything they had done, but for where they lived. In October 2024, the Linux kernel quietly struck eleven Russian maintainers from its MAINTAINERS file. These were people who had looked after drivers and subsystems for years, and the reason given was "compliance requirements" tied to US sanctions on Russia. When the community protested, Linus Torvalds answered bluntly: the decision stood. Russia's Ministry of Digital Transformation began talking of forking Linux entirely — a sentence that would have read as satire ten years before.

Meanwhile, RISC-V International, the body governing the open chip architecture, had already moved from the United States to Switzerland in 2020, on the plain grounds that US export controls could be used to bar participation. US lawmakers called the move "short-sighted" and pushed for controls on RISC-V itself — controls that, by the government's own admission, would be nearly impossible to enforce on an open standard already published worldwide, a detail which did not seem to trouble them.

In Europe, the Cyber Resilience Act brought new compliance duties that open source bodies warned could have a "chilling effect on open source software development as a global endeavour." An open letter signed by thirteen organisations, including the Eclipse Foundation and the Open Source Initiative, argued that seventy percent of Europe's software was about to be regulated without proper consultation with the people who write it.

The pattern was clear, and it belonged to no single country or conflict. US-based foundations found themselves enforcing OFAC sanctions and NDAA rules that limited who could take part, not by choice, but by force of law. China answered with its own bodies, including the Open Atom Foundation, chartered in open step with state leadership. Russia moved toward sovereign alternatives. Europe piled on regulation. Everywhere, the belief that had held open source together for decades — that openness alone was enough to build trust, draw talent, and bring the world together — was cracking along borders.

Open source is a form. It makes code visible. But visibility at the code level does not create trust at the organisational level, any more than an open door makes your neighbours trust your character. And as blocs hardened, the gap between "our code is open" and "we are trusted" grew wider everywhere.

## The backdoor that proved the point

In March 2024, a Microsoft engineer named Andres Freund noticed that SSH logins on his Debian test system were taking half a second longer than they should. Most people would have blamed systemd and moved on. Freund dug in, and found one of the most careful supply chain attacks in the history of open source software.

A contributor using the name Jia Tan had spent over two years — patiently, step by step — winning the trust of Lasse Collin, the Finnish volunteer who alone maintained XZ Utils, a compression library buried deep in the Linux dependency chain. Collin had spoken openly about his burnout and mental health struggles. Fake accounts appeared on the project's mailing list, pressing him to accept help. Bit by bit, Jia Tan gained co-maintainer access, then full release authority.

In early 2024, Jia Tan planted a backdoor in XZ Utils. The library was linked into the OpenSSH server daemon through systemd on many Linux distributions; anyone holding a certain cryptographic key could silently bypass SSH login checks. Had it not been caught — by luck, because of a 400-millisecond delay that one curious engineer refused to ignore — it would have reached stable distributions within months, granting silent access to millions of servers worldwide.

The person behind "Jia Tan" has never been firmly identified. What we do know is this: the open source model had no way at all to check who this person was, what body they served, or whether their two years of helpful work were honest or groundwork for attack. The trust was wholly informal, wholly personal, and wholly unfit for systems the world depends on.

## What is needed

The XZ incident shook me awake. What I had feared most was now hurting what I loved most. I had spent my career in open source because I believed in its promise: that openness builds trust, that shared code builds common ground, that transparency is the answer to suspicion. And here was proof that the promise, left unguarded, could be turned against itself. A nameless attacker had used the very culture of openness — the readiness to welcome strangers, the faith in good work — to plant a backdoor in systems the world depends on.

The XZ incident did not prove that open source is broken. It proved that a layer is missing — a layer of trust that sits above the code and below the politics — and that no one was building it.

At that time I was in Singapore, and with the help of like-minded friends there, we chose to build it ourselves. We thought of calling it the "Open Source Trust Foundation," but that was too long, so we settled on `opensource.foundation`. We registered it in 2024, in Singapore, outside any single bloc's legal reach, with a vision that had been forming, without my quite knowing it, since that morning by the river in Coomera.

Not more code openness. The code was never the problem. What is needed is organisational trust: a neutral body that can independently audit software supply chains, vouch for the origin of contributions, and certify that a project or organisation meets a clear standard of integrity, wherever its contributors sit. A place where an engineer in Shenzhen and a maintainer in Helsinki and a compliance officer in Brussels can all point to the same independent check and say: *this is trustworthy, and here is why*.

That is the foundation we are building. It exists for the plainest of reasons: open source deserves better than to have its promise broken by the very forces it was meant to rise above.

---

*Weiwu Zhang is the Chairman of opensource.foundation. He is an Australian citizen of Chinese heritage and has worked in open source technology for over a decade.*
