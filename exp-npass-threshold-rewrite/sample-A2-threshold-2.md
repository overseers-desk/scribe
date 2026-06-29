---
title: "Our Story"
description: "How a season of jacaranda blossoms, a 5G ban, and a backdoor that nearly broke the internet led to opensource.foundation"
draft: false
---

## The jacarandas were blooming

It was October 2018. I was having coffee at Coomera River, in a scenic café called Historic Rivermill. The trees were in full bloom. The whole river bank turned violet; the blossoms falling so thickly they carpeted the footpaths. The air warm, the light long, everything signalling change.

That spring, something else was changing. Two months earlier, Australia had become the first country in the world to ban Huawei equipment from its 5G networks. The Telecommunications Sector Security Reforms had passed, and the government's assessment was blunt: no technical safeguard could reduce the risk when a foreign government can secretly compel a vendor to act.

I was speaking with engineers and managers from Huawei at the time, as well as contractors who had been implementing their systems. Many of them felt they were being wronged. Their argument was open source: Huawei's infrastructure ran on open source components, and the company put serious work into contributing code back to the projects it used. The code was open. Anyone could read it. Wasn't that the whole point?

But when I pressed, even the most confident among them admitted something uncomfortable. Effectively, none of them are sure if they are *really* innocent. Their internal version control wasn't effectively managing every fork. When engineers modified a component for a specific network rollout, no one could easily tell whether the shipped version still matched the original open source code. The code might be open, but the chain from open source repository to deployed system was not fully transparent.

I asked myself a question that stayed with me: *Is this temporary? Will the trust come back once the politics cool down?*

## It didn't come back

In May 2019, the United States placed Huawei and 68 affiliates on the Entity List, requiring a government licence for any American company to sell technology to them. In 2020, the US tightened the Foreign Direct Product Rule to cut Huawei off from advanced chip-making, even at overseas factories that used American equipment. What had started as one country's security assessment became a global decoupling.

And it wasn't just China.

In 2019, GitHub, the platform where most of the world's open source lives, began restricting accounts in Iran, Syria, Crimea, and Cuba to comply with US sanctions. Developers who had contributed to open source for years found their private repositories locked overnight, not because of anything they had done, but because of where they lived. In October 2024, the Linux kernel quietly removed eleven Russian maintainers from its MAINTAINERS file. These were people who had maintained drivers and subsystems for years, and the justification cited was "compliance requirements" linked to US sanctions on Russia. When the community protested, Linus Torvalds responded bluntly: the decision was not getting reverted. Russia's Ministry of Digital Transformation began discussing forking Linux entirely — a sentence that would have read as satire ten years ago.

Meanwhile, RISC-V International, the body governing the open chip architecture, relocated from the United States to Switzerland in 2020, arguing that US export controls could be used to restrict who takes part. US lawmakers called the move "short-sighted" and pushed for controls on RISC-V itself — controls that, by the government's own admission, would be nearly impossible to enforce on an open standard already published worldwide, a detail which did not appear to trouble them.

In Europe, the Cyber Resilience Act imposed new rules that open source bodies warned could have a "chilling effect on open source software development as a global endeavour." An open letter from thirteen organisations, including the Eclipse Foundation and the Open Source Initiative, warned that the regulation would cover seventy percent of Europe's software without consulting the people who write it.

The pattern was unmistakable, and no single country or conflict owned it. US-incorporated foundations found themselves enforcing OFAC and NDAA sanctions that limited who could take part — not by choice, but because American law required it. China built its own bodies, including the Open Atom Foundation, which openly aligned itself with state leadership. Russia moved toward sovereign alternatives. Europe layered regulation. Everywhere, the old faith that openness alone could earn trust, draw talent, and unite the world — was breaking apart along national borders.

Open source is a form. It makes code transparent. But seeing the code does not make you trust the people behind it, any more than an unlocked door makes you trust your neighbour. And as nations drew sharper lines, the distance between "our code is open" and "we are trusted" kept growing.

## The backdoor that proved the point

In March 2024, a Microsoft engineer named Andres Freund noticed that SSH logins on his Debian test system were taking half a second longer than they should. Most people would have muttered something about systemd and moved on. Freund investigated, and uncovered one of the most carefully planned attacks ever hidden inside open source software.

A contributor using the pseudonym Jia Tan had spent over two years — patiently, methodically — building trust with Lasse Collin, the Finnish volunteer who single-handedly maintained XZ Utils, a compression library that thousands of Linux programs rely on. Collin had publicly spoken about his burnout and mental health struggles. Sock puppet accounts appeared on the project's mailing list, pressuring him to accept help. Gradually, Jia Tan gained co-maintainer access, then full release authority.

In early 2024, Jia Tan inserted a backdoor into XZ Utils. On many Linux systems, the library ran inside the SSH login process; anyone who held a specific secret key could silently bypass authentication. If one curious engineer had not noticed — by chance, because of a 400-millisecond delay he refused to ignore — the backdoor would have shipped to millions of servers within months, granting silent access worldwide.

No one has ever identified who "Jia Tan" really is. What we do know is this: the open source model had no way to verify who this person was, what institution they served, or whether their two years of helpful work were genuine or groundwork for an attack. The trust was entirely informal, entirely personal, and entirely inadequate for infrastructure that the world depends on.

## What is needed

The XZ incident was a wake-up call for me. What I had feared the most was now hurting what I loved the most. I had spent my career in open source because I believed in its promise: that transparency builds trust, that shared code builds shared ground, that openness defeats suspicion. And here was proof that without safeguards, that promise could become a weapon. An attacker behind a false name had exploited the very culture of openness — the willingness to welcome strangers, the faith in good work — to slip malicious code into infrastructure the world depends on.

The XZ incident did not prove that open source is broken. It proved that a layer is missing — a layer of trust that sits above the code and below the politics — and that no one was building it.

I was in Singapore then, and with friends who shared the same concern, we decided to build it ourselves. We thought about calling it the "Open Source Trust Foundation," but the name was too long, so we went with `opensource.foundation`. We registered it in 2024, in Singapore, outside any single bloc's legal reach, with a vision that had been forming, without my quite realising it, since that morning by the river in Coomera.

Not more code transparency. The code was never the problem. What is needed is organisational trust: a neutral body that can check where software comes from, confirm who wrote it, and certify that a project or organisation meets a clear standard of integrity — no matter where its contributors sit. A place where an engineer in Shenzhen and a maintainer in Helsinki and a compliance officer in Brussels can all point to the same independent verification and say: *this is trustworthy, and here is why*.

That is the foundation we are building. It exists because the very pressures open source set out to overcome should not be the ones that break its promise.

---

*Weiwu Zhang is the Chairman of opensource.foundation. He is an Australian citizen of Chinese heritage and has worked in open source technology for over a decade.*
