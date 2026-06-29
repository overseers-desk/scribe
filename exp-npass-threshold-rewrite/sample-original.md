---
title: "Our Story"
description: "How a season of jacaranda blossoms, a 5G ban, and a backdoor that nearly broke the internet led to opensource.foundation"
draft: false
---

## The jacarandas were blooming

It was October 2018. I was having coffee at Coomera River, in a scenic café called Historic Rivermill. The trees were in full bloom. The whole river bank turned violet; the blossoms falling so thickly they carpeted the footpaths. The air warm, the light long, everything signalling change.

That spring, something else was changing. Two months earlier, Australia had become the first country in the world to ban Huawei equipment from its 5G networks. The Telecommunications Sector Security Reforms had passed, and the government's assessment was blunt: no combination of technical controls could sufficiently mitigate the risks posed by vendors subject to extrajudicial direction from a foreign government.

I was speaking with engineers and managers from Huawei at the time, as well as contractors who had been implementing their systems. Many of them felt they were being wronged. Their argument was opensource: Huawei's infrastructure relied heavily on open source components, and the company invested real effort in contributing upstream. The code was open. Anyone could read it. Wasn't that the whole point?

But when I pressed, even the most confident among them admitted something uncomfortable. Effectively, none of them are sure if they are *really* innocent. Their internal version control wasn't effectively managing every fork. When a component was customised for a carrier deployment, it was difficult to trace whether the shipped version still corresponded to the validated open source codebase. The code might be open, but the chain from open source repository to deployed system was not fully transparent.

I asked myself a question that stayed with me: *Is this temporary? Will the trust come back once the politics cool down?*

## It didn't come back

In May 2019, the United States placed Huawei and 68 affiliates on the Entity List, requiring a government licence for any American company to sell technology to them. In 2020, the Foreign Direct Product Rule was tightened to cut Huawei off from advanced semiconductor manufacturing, even at overseas foundries that used American equipment. What had started as one country's security assessment became a global decoupling.

And it wasn't just China.

In 2019, GitHub, the platform where most of the world's open source lives, began restricting accounts in Iran, Syria, Crimea, and Cuba to comply with US sanctions. Developers who had contributed to open source for years found their private repositories locked overnight, not because of anything they had done, but because of where they lived. In October 2024, the Linux kernel quietly removed eleven Russian maintainers from its MAINTAINERS file. These were people who had maintained drivers and subsystems for years, and the justification cited was "compliance requirements" linked to US sanctions on Russia. When the community protested, Linus Torvalds responded bluntly: the decision was not getting reverted. Russia's Ministry of Digital Transformation began discussing forking Linux entirely — a sentence that would have read as satire ten years ago.

Meanwhile, RISC-V International, the body governing the open chip architecture, had already relocated from the United States to Switzerland in 2020, on the explicit grounds that US export controls could be used to restrict participation. US lawmakers called the move "short-sighted" and pushed for controls on RISC-V itself — controls that, by the government's own admission, would be nearly impossible to enforce on an open standard already published worldwide, a detail which did not appear to trouble them.

In Europe, the Cyber Resilience Act introduced new compliance obligations that open source bodies warned could have a "chilling effect on open source software development as a global endeavour." An open letter signed by thirteen organisations, including the Eclipse Foundation and the Open Source Initiative, argued that seventy percent of Europe's software was about to be regulated without adequate consultation with the people who write it.

The pattern was unmistakable, and it was not confined to any one country or any one conflict. US-incorporated foundations found themselves enforcing OFAC sanctions and NDAA restrictions that limited who could participate, not by the foundations' choice, but by operation of law. China responded with its own institutional structures, including the Open Atom Foundation, chartered with explicit alignment to state leadership. Russia moved toward sovereign alternatives. Europe layered regulation. Everywhere, the assumption that had sustained open source for decades, that openness itself was sufficient to establish trust, attract talent, and integrate globally — was fracturing along jurisdictional lines.

Open source is a form. It makes code transparent. But transparency at the code level does not produce trust at the organisational level, any more than an open door makes your neighbours trust your character. And as geopolitical blocs hardened, the gap between "our code is open" and "we are trusted" grew wider in every direction.

## The backdoor that proved the point

In March 2024, a Microsoft engineer named Andres Freund noticed that SSH logins on his Debian test system were taking half a second longer than they should. Most people would have muttered something about systemd and moved on. Freund investigated, and uncovered one of the most sophisticated supply chain attacks in the history of open source software.

A contributor using the pseudonym Jia Tan had spent over two years — patiently, methodically — building trust with Lasse Collin, the Finnish volunteer who single-handedly maintained XZ Utils, a compression library embedded deep in the Linux dependency chain. Collin had publicly spoken about his burnout and mental health struggles. Sock puppet accounts appeared on the project's mailing list, pressuring him to accept help. Gradually, Jia Tan gained co-maintainer access, then full release authority.

In early 2024, Jia Tan inserted a backdoor into XZ Utils. The library was linked into the OpenSSH server daemon via systemd on many Linux distributions; anyone possessing a specific cryptographic key could silently bypass SSH authentication. Had it not been caught — by chance, on account of a 400-millisecond delay that one curious engineer refused to ignore — it would have reached stable distributions within months, granting silent access to millions of servers worldwide.

The identity behind "Jia Tan" has never been conclusively established. What is established is this: the open source model had no mechanism whatsoever for verifying who this person was, what institution they represented, or whether their two years of helpful contributions were genuine or preparation for attack. The trust was entirely informal, entirely personal, and entirely inadequate for infrastructure that the world depends on.

## What is needed

The XZ incident was a wake-up call for me. What I had feared the most was now hurting what I loved the most. I had spent my career in open source out of belief in its promise: that transparency builds trust, that shared code builds shared ground, that openness is the antidote to suspicion. And here was the proof that the promise, left unprotected, could be turned against itself. A pseudonymous attacker had weaponised the very culture of openness, the willingness to welcome strangers, the faith in good contributions, to plant a backdoor in infrastructure the world depends on.

The XZ incident did not prove that open source is broken. It proved that a layer is missing — a layer of trust that sits above the code and below the politics — and that no one was building it.

At that time I was in Singapore, and with the help of like-minded friends there, we decided to build it ourselves. We considered calling it the "Open Source Trust Foundation," but that turned out to be such a mouthful, so we settled on `opensource.foundation`. We registered it in 2024, in Singapore, outside any single bloc's legal reach, with a vision that had been forming, without my quite realising it, since that morning by the river in Coomera.

Not more code transparency. The code was never the problem. What is needed is organisational trust: a neutral body that can independently audit software supply chains, attest to the provenance of contributions, and certify that a project or organisation meets a defined standard of integrity, regardless of where its contributors sit. A place where an engineer in Shenzhen and a maintainer in Helsinki and a compliance officer in Brussels can all point to the same independent verification and say: *this is trustworthy, and here is why*.

That is the foundation we are building. It exists for the plainest of reasons: open source deserves better than to have its promise broken by the very forces it was meant to transcend.

---

*Weiwu Zhang is the Chairman of opensource.foundation. He is an Australian citizen of Chinese heritage and has worked in open source technology for over a decade.*
