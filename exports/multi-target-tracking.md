# Multi-Target Tracking, From First Principles
*Bayesian estimation → Kalman → association → MHT → IMM → designing a tracker*

> A spaced-repetition primer. Read the prose; answer the **Q/A** cards from memory; review on an SRS schedule (1d, 3d, 7d, 16d, …). Cards are atomic — one fact, one retrieval.

A ground-up, Quantum-Country-style primer on multi-target tracking. Climbs from recursive Bayesian estimation and the Kalman filter (built rung by rung) through EKF/UKF/particle filters, coordinate frames and nonlinear measurement models, sensor fusion, kinematic models, gating and data association (GNN/JPDA), Multiple Hypothesis Tracking, the IMM filter, track management and target typing — ending at a capstone where you can architect and tune a full tracker yourself.


## What tracking is: the detect → predict → associate → update → manage pipeline

*A tracker turns a stream of noisy, intermittent, ambiguously-sourced sensor detections into a small set of confident estimates of where real objects are and where they are going. This node frames the whole course: it defines the detect→predict→associate→update→manage loop, distinguishes single-target from multi-target tracking, and isolates the two coupled hard problems — estimation (filtering noise to recover state) and association (deciding which measurement, if any, came from which target) — that every later rung attacks.*

Imagine you are sitting in front of a radar console. Every few seconds the antenna sweeps the sky and hands you a fresh pile of *detections*: little blips, each one a position report — say a range and a bearing — possibly with a measured speed. Your job sounds simple. Tell me how many aircraft are out there, where each one is right now, and where each one will be thirty seconds from now. That is **tracking**, and it is one of the oldest hard problems in applied estimation. The reason it is hard is that the blips lie to you in three different ways at once, and the rest of this course is essentially a guided tour of how engineers learned to stop being fooled by each kind of lie.

The **first lie is noise**. The blip never sits exactly on the target. The measured range is the true range plus a random error; the bearing wobbles. If you simply plotted each blip and called it 'the position,' your track would jitter wildly and your velocity estimate — which you get by differencing successive positions — would be pure garbage, because differencing *amplifies* noise. So you cannot trust any single measurement. You must *combine* measurements over time, weighting the new evidence against what you already believe. That weighted combination, done optimally, is **estimation** (also called filtering). The recursive predict-then-correct heartbeat of estimation (n1-bayes), the Gaussian state-space machinery that makes it tractable (n1-statespace), and the long climb from a humble moving average (n2-averaging) through the alpha-beta filter (n2-alphabeta) up to the full multivariate Kalman filter (n2-matrixkf) are the spine of the first third of this course. Everything there answers one question: *given that I know these measurements came from this one target, what is my best estimate of its state?*

The **second lie is the gap**. The target is not always detected. Clouds, terrain, low radar cross-section, or just bad luck mean that on any given scan a real aircraft may produce no blip at all. The probability of detection $P_D$ is rarely 1; in hard scenarios it might be 0.7 or worse. Conversely, the sensor invents blips that correspond to nothing — *clutter* and *false alarms* from sea spray, birds, thermal noise. So the number of detections you receive on a scan is not the number of targets. This is why you must **predict**: between updates, you propagate each existing track forward in time using a *motion model* (n7-kinematic) so that you have a prediction to compare against the next scan even when a target was missed. Prediction is what lets a track coast through a missed detection and survive.

The **third lie, and the one that makes *multi*-target tracking a genuinely different and harder beast than single-target tracking, is anonymity**. The blips are not labeled. When two aircraft are flying near each other and you get two blips, nothing on the radar tells you which blip belongs to which aircraft. With $N$ existing tracks and $M$ new detections (plus the possibilities that a detection is clutter and that a track was missed), the number of ways to explain the scan explodes combinatorially. Deciding which measurement updates which track — the **data association** problem — is the second great hard problem of tracking, and it is *entirely absent* from single-target estimation. This is the crucial conceptual split. **Single-target tracking** assumes every measurement (after gating out clutter) belongs to the one target you care about; the only enemy is noise, so it is a pure estimation problem. **Multi-target tracking (MTT)** adds association on top of estimation, and the two are coupled: you need good estimates to associate correctly (to know which track a blip is *near*), and you need correct associations to keep your estimates good (feed a track the wrong blip and it diverges). That chicken-and-egg coupling is the engine that drives the entire back half of the course — gating (n8-gating), nearest-neighbour and the assignment problem (n8-gnn), probabilistic data association (n8-jpda), multiple hypothesis tracking (n9-mht-foundations, n9-mht-variants), and the interacting multiple model filter for maneuvers (n10-imm).

The standard architecture that tames all three lies is a recursive loop run once per scan. It has five stages, and you should memorize them as a cycle, because every algorithm in this course is a different way of implementing one or more of these stages:

1. **Detect** — the sensor (or its signal-processing front end) produces this scan's set of measurements: threshold-crossing detections, each a point in measurement space, some real and some clutter.
2. **Predict** — for every existing track, use the motion model to propagate the state estimate $\hat{x}$ and its covariance $P$ forward to the time of this scan. Propagating $P$ through the transition $F$ and adding process noise $Q$ gives the predicted covariance, from which we form the predicted measurement $H\hat{x}$ and the innovation covariance $S = HPH^\top + R$. This is where the track 'expects' to see its target.
3. **Associate** — decide which measurement(s) explain which track. First *gate* (reject any measurement too far from a prediction to be plausible — measured by the Mahalanobis distance against $S$), then assign survivors to tracks. The innovation $\nu = z - H\hat{x}$, the gap between what you saw and what you predicted, is the raw material of association.
4. **Update** — for each track, fold its associated measurement into the estimate using the Kalman gain $K = PH^\top S^{-1}$, correcting $\hat{x} \leftarrow \hat{x} + K\nu$ and shrinking $P$. Noise gets filtered here.
5. **Manage** — the bookkeeping of *existence*: start new tentative tracks from unassociated measurements, confirm tracks that have accumulated enough evidence (e.g. M-of-N logic, n11-trackmgmt), and delete tracks that have gone too long without support. This is what keeps the *number* of tracks honest.

Then the loop repeats on the next scan. **Detect → predict → associate → update → manage.** Notice that estimation lives in predict+update, and association lives in associate+manage, and the loop is what couples them.

**A worked numerical example, to make the two problems concrete.** Suppose we track position only, in 1-D, measuring position directly so $H = 1$. A track currently predicts the target at $\hat{x} = 100$ m. Its prior position variance is $P = 16$ m$^2$ and the measurement-noise variance is $R = 9$ m$^2$, so the innovation covariance is $S = HPH^\top + R = 16 + 9 = 25$ m$^2$ (a predicted-measurement standard deviation of $\sqrt{S} = 5$ m). A new scan delivers two detections: $z_A = 103$ m and $z_B = 130$ m. First the *association* question: which blip, if any, is our target? The normalized squared distance (a Mahalanobis distance, the chi-square statistic we will formalize in n8-gating) for each is $d^2 = \nu^2 / S$, where $\nu = z - H\hat{x}$. For A: $\nu_A = 103-100 = 3$, so $d_A^2 = 9/25 = 0.36$. For B: $\nu_B = 130-100 = 30$, so $d_B^2 = 900/25 = 36$. With a typical 1-D gate threshold around $d^2 \le 9$ (a $3\sigma$ gate, since $d^2 \sim \chi^2_1$), detection A falls comfortably inside the validation region and B falls wildly outside — B is rejected as either clutter or another target's measurement. So association picks A. *Only then* does the *estimation* question arise: how far should I move my estimate toward $103$? Not all the way — that would trust the noisy blip completely. The Kalman update moves the estimate by $K\nu$, where the gain $K = PH^\top S^{-1} = P/(P+R)$ in this scalar case. With $P = 16$ and $R = 9$, $K = 16/(16+9) = 0.64$, so the updated estimate is $\hat{x} + K\nu = 100 + 0.64 \times 3 = 101.9$ m, and the variance shrinks to $(1-K)P = 0.36 \times 16 = 5.76$ m$^2$. We moved partway, and we got *more certain*. Two questions, two machineries: association chose the blip, estimation chose how much to believe it. Get the association wrong — feed the track $z_B = 130$ instead — and the estimate lurches to $100 + 0.64\times 30 = 119.2$ m, corrupting all future predictions. That fragility is exactly why association deserves half a course.

*(historical and accurate)* The recursive predict-then-correct philosophy at the heart of stages 2 and 4 was crystallized by Rudolf E. Kálmán in his 1960 paper 'A New Approach to Linear Filtering and Prediction Problems' (Transactions of the ASME, Journal of Basic Engineering, vol. 82, Series D, pp. 35–45). Its first famous real-world application was not in radar at all but in spaceflight: after Kálmán visited NASA Ames Research Center in the fall of 1960, Stanley F. Schmidt's Dynamics Analysis Branch adapted the filter over 1960–61 to the nonlinear Apollo circumlunar midcourse-navigation problem, validating it in simulation by early 1961. In doing so — by linearizing the dynamics about the filter's *latest estimate* rather than a fixed reference trajectory — Schmidt's group originated what we now call the Extended Kalman Filter (n4-ekf), the variant later carried in the Apollo onboard computer. Tracking and navigation have been intertwined ever since.

*(historical and accurate)* The association problem — the part that has *nothing* to do with Kalman and *everything* to do with multi-target tracking — was given its first rigorous probabilistic treatment by Robert W. Sittler in 'An Optimal Data Association Problem in Surveillance Theory' (IEEE Transactions on Military Electronics, vol. MIL-8, pp. 125–139, April 1964). Sittler's examples already clarified the distinction between *tentative*, *confirmed*, and *established* tracks that survives almost unchanged in modern track-management logic (n11-trackmgmt). The full combinatorial machinery — deferring association decisions across multiple scans and maintaining a tree of hypotheses — arrived with Donald B. Reid's 'An Algorithm for Tracking Multiple Targets' (IEEE Transactions on Automatic Control, vol. 24, no. 6, pp. 843–854, 1979), the founding paper of Multiple Hypothesis Tracking (n9-mht-foundations).

*(historical and accurate)* The earliest large-scale automated tracker predates all of this theory: the SAGE (Semi-Automatic Ground Environment) continental air-defense system, whose air-defense concept was driven by George Valley and whose real-time computing grew out of Jay Forrester's Whirlwind, developed largely at MIT Lincoln Laboratory. Its first center became operational on 1 July 1958. Its computers correlated raw radar returns across many sites into 'tracks' in real time — arguably the first operational detect→associate→track pipeline, built before the Kalman filter (1960) existed to do the estimation step optimally.

*(practical)* The two canonical modern references that organize this entire field along exactly the estimation-versus-association split used in this course are Yaakov Bar-Shalom and Thomas E. Fortmann's *Tracking and Data Association* (Academic Press, 1988) and Samuel S. Blackman and Robert Popoli's *Design and Analysis of Modern Tracking Systems* (Artech House, 1999). If you remember one organizing idea from this node, let it be theirs: a tracker is an estimation engine wrapped inside an association engine, looping once per scan.


**Q:** Name the five stages of the standard recursive tracking loop, in order.

**A:** Detect → predict → associate → update → manage.

**Q:** Tracking is built around two coupled hard problems. Name both.

**A:** Estimation (filtering) and association (data association).

**Q:** In tracking, which of the two hard problems is responsible for recovering a target's state from noisy data, and which is responsible for deciding which measurement came from which target?

**A:** Estimation (filtering) recovers state from noisy data; association (data association) decides which measurement, if any, came from which target.

**Q:** What is the single defining problem that multi-target tracking has but single-target tracking does NOT?
  a) The need to filter measurement noise out of the position reports
  b) The data-association ambiguity: unlabeled detections must be matched to the correct target
  c) The need to predict a target's future position from a motion model
  d) The fact that the probability of detection is less than one

**A:** The data-association ambiguity: unlabeled detections must be matched to the correct target — Noise filtering (estimation), motion-model prediction, and missed detections all appear in single-target tracking too. What is genuinely new in MTT is anonymity: with several targets, an unlabeled blip could belong to any of them, creating the combinatorial data-association problem. Single-target tracking assumes (after gating) every measurement is from the one target, so it has no association problem.

**Q:** Why can't a tracker just report each raw detection as the target's position and difference consecutive positions to get velocity?

**A:** Each detection carries random measurement noise, so reported positions jitter; and differencing two noisy positions amplifies that noise, producing a useless velocity estimate. You must combine measurements over time (filter) rather than trust any single one.

**Q (cloze):** Between scans, the ____ stage propagates a track forward so it has something to compare the next scan against even through a missed detection; the ____ stage handles track existence — initiating, confirming, and deleting tracks.

**A:** Between scans, the **predict** stage propagates a track forward so it has something to compare the next scan against even through a missed detection; the **manage** stage handles track existence — initiating, confirming, and deleting tracks.

**Q:** A track predicts position 100 m with innovation covariance S = 25 m². Two detections arrive: 103 m and 130 m. Using the normalized squared distance d² = ν²/S and a gate threshold of d² ≤ 9, which detection(s) fall inside the validation region?

**A:** Only the 103 m detection. For it ν = 3, d² = 9/25 = 0.36 ≤ 9 (inside). For 130 m, ν = 30, d² = 900/25 = 36 > 9 (rejected).

**Q:** A track predicts position 100 m with prior variance P = 16 m² and measurement noise R = 9 m² (H = 1). After association picks the detection at 103 m, compute the scalar Kalman gain K = P/(P+R) and use it to compute the updated position estimate x̂ + K(z − x̂).

**A:** K = 16/(16+9) = 0.64; updated estimate = 100 + 0.64×(103−100) = 100 + 0.64×3 = 101.9 m.

**Q:** After a scalar Kalman update with gain K = 0.64 and prior variance P = 16 m², what is the updated (posterior) variance, using (1−K)P?

**A:** (1−0.64)×16 = 0.36×16 = 5.76 m². The estimate became more certain (variance shrank from 16 to 5.76).

**Q:** Explain why estimation and association are coupled — i.e. why you can't simply solve one and then the other once and for all.

**A:** Good estimates are needed to associate correctly: you decide which blip belongs to a track by how near it is to that track's prediction, which requires an accurate predicted state and covariance. But correct associations are needed to keep estimates good: feed a track a measurement from a different target or from clutter and the update corrupts its state, which then corrupts future predictions and hence future associations. The two feed each other every scan, so they must be solved jointly (or iteratively) in the recursive loop, not sequentially once.

**Q:** The SAGE air-defense system formed aircraft 'tracks' from raw radar in the late 1950s, before the Kalman filter (1960) existed to do optimal estimation. What does that fact reveal about which part of the detect→predict→associate→update→manage pipeline is most fundamental?

**A:** It shows the detect→associate→manage backbone — forming and maintaining the existence of tracks from ambiguous returns using simple prediction and gating logic — is the irreducible core of a tracker. Optimal estimation (the Kalman update) can be bolted on later to refine each track's state, but without association and management there are no tracks to refine. SAGE (MIT Lincoln Laboratory, operational 1 July 1958) demonstrated this by correlating returns into tracks years before Kalman's optimal filter appeared.


## Recursive Bayesian estimation: the predict–update heartbeat

*Tracking is inference about a hidden state we never see directly. Bayesian estimation maintains a probability distribution (belief) over the state, and recursion lets us update that belief one measurement at a time without re-processing history: prior → predict (Chapman–Kolmogorov) → likelihood → posterior (Bayes), repeated forever.*

In n0 we sketched the pipeline: detect, predict, associate, update, manage. The two middle words — *predict* and *update* — are not arbitrary engineering steps. They are the two halves of a single, deep idea that every tracker on Earth is built on: **recursive Bayesian estimation**. This node builds that idea from nothing, so that the Kalman filter (later) becomes merely *one special case* you could have re-derived yourself.

**Why we need probability at all.** The target has a true state — say its 2-D position and velocity, $x = [p_x, p_y, v_x, v_y]^\top$. We never observe $x$. We observe *measurements* $z$: a radar return at a noisy range and bearing, a pixel blob, a lidar point. The measurement is corrupted (sensor noise) and incomplete (a range/bearing report says nothing directly about velocity). So we are permanently uncertain. The honest representation of "what we know about $x$ right now" is therefore not a single number but a **probability distribution** $p(x)$ — our *belief*. A wide distribution means "could be lots of places"; a narrow spike means "we're confident." Tracking *is* the art of maintaining and sharpening this belief as data arrives.

**The two ingredients of a tracking problem.** (1) A *motion model* (a.k.a. transition / dynamics / process model): a rule for how the state at time $k-1$ probabilistically becomes the state at time $k$, written as the transition density $p(x_k \mid x_{k-1})$. (2) A *measurement model* (likelihood): how a state $x_k$ probabilistically produces an observation, written $p(z_k \mid x_k)$. Crucially we assume the **Markov property** — the future depends on the past only through the present: $p(x_k \mid x_{0:k-1}) = p(x_k \mid x_{k-1})$ — and **conditional independence of measurements** given the state: $z_k$ depends only on $x_k$. A process satisfying both is a *hidden Markov model* / *state-space model* (formalized in n1-statespace). These two assumptions are what make recursion possible.

**Bayes' rule, the engine.** Given a *prior* belief $p(x_k \mid z_{1:k-1})$ (everything we knew before seeing $z_k$) and a new measurement $z_k$, Bayes' rule produces the *posterior*:
$$ p(x_k \mid z_{1:k}) = \frac{\overbrace{p(z_k \mid x_k)}^{\text{likelihood}}\,\overbrace{p(x_k \mid z_{1:k-1})}^{\text{prior}}}{\underbrace{p(z_k \mid z_{1:k-1})}_{\text{evidence (normalizer)}}}. $$
In words: **posterior $\propto$ likelihood $\times$ prior**. The likelihood reweights each candidate state by how well it explains the data we actually saw; the denominator just renormalizes so the result is a valid distribution. This is the **update** step.

**But where does the prior come from? Prediction.** Before $z_k$ arrives, we already have last step's posterior $p(x_{k-1} \mid z_{1:k-1})$. We push it forward through the motion model with the **Chapman–Kolmogorov equation**:
$$ p(x_k \mid z_{1:k-1}) = \int p(x_k \mid x_{k-1})\, p(x_{k-1} \mid z_{1:k-1})\, dx_{k-1}. $$
This is the **predict** step: integrate over all the places the target *could* have been, weighted by how likely it was to be there, propagating each through the dynamics. Prediction always *spreads out* (increases uncertainty) because the motion model is itself uncertain; the update *contracts* it because a measurement adds information.

**The heartbeat.** Now stack them: predict turns yesterday's posterior into today's prior; update turns today's prior into today's posterior; repeat. That is the **recursive** part, and it is the whole point. We never store or re-touch $z_{1:k-1}$ — the posterior $p(x_{k-1}\mid z_{1:k-1})$ is a *sufficient statistic* that compresses all past data. A tracker running for ten hours uses the same memory and per-step compute as one running for ten seconds. *(practical)* This is why a 1960s guidance computer with a few kilobytes could track a spacecraft: recursion means "remember the belief, forget the raw data."

**A worked numerical example (discrete, no calculus).** A robot lives in 3 cells $\{A,B,C\}$. Prior belief: $p = (0.5, 0.3, 0.2)$. *Motion model:* each step it tends to drift right (stay 70%, move to the next cell 30%; C wraps to A). *Predict:* new belief at A = $0.5\cdot0.7 + 0.2\cdot0.3 = 0.41$; at B = $0.3\cdot0.7 + 0.5\cdot0.3 = 0.36$; at C = $0.2\cdot0.7 + 0.3\cdot0.3 = 0.23$. Note the distribution flattened slightly (entropy rose) — prediction spreads belief. *Now a sensor fires* with likelihood $p(z\mid \cdot) = (0.1, 0.8, 0.1)$ — it strongly suggests cell B. *Update:* multiply elementwise → $(0.041, 0.288, 0.023)$, sum $= 0.352$ (this is the evidence), renormalize → $(0.116, 0.818, 0.065)$. Belief collapsed onto B; the measurement *contracted* the distribution. Run predict→update again with the next reading and you have a tracker. The Kalman filter is exactly this loop, with the simplifying choice that every distribution is Gaussian so the integrals become matrix algebra.

**Why this is hard in general.** For arbitrary $p(x_k\mid x_{k-1})$ and $p(z_k\mid x_k)$, the Chapman–Kolmogorov integral and the Bayes normalizer are intractable — that is precisely why later nodes introduce the linear-Gaussian shortcut (Kalman), local linearization (EKF), deterministic sampling (UKF), and Monte-Carlo sampling (particle filters). Every one of those is just a *tractable way to carry out predict and update*. Keep this map in mind: the destinations differ, but the road is always the same two steps.

*(historical and accurate)* The Bayesian engine itself predates tracking by two centuries. The Rev. Thomas Bayes (who died 7 April 1761) never published his rule; his "An Essay towards solving a Problem in the Doctrine of Chances" was communicated posthumously by his friend Richard Price — in a letter to John Canton dated 10 November 1763 — and read to the Royal Society on 23 December 1763, more than two years after Bayes' death (it appeared in the Philosophical Transactions, vol. 53, pp. 370–418). The recursive *filtering* form — propagate a belief through dynamics, then condition on a measurement — is the modern synthesis whose most famous instance, the linear-Gaussian case, was published by Rudolf E. Kálmán in 1960 (next node).


**Q:** In recursive Bayesian estimation, what mathematical object represents our knowledge of the hidden state at a given time?

**A:** A probability distribution over the state — the 'belief' p(x).

**Q:** Name the two recurring steps of the recursive Bayesian filtering loop, in order.

**A:** Predict, then update.

**Q (cloze):** posterior $\propto$ ____ $\times$ ____

**A:** posterior $\propto$ **likelihood** $\times$ **prior**

**Q:** Which equation implements the predict step, and what operation does it perform on the previous posterior?

**A:** The Chapman–Kolmogorov equation; it integrates the previous posterior against the transition density p(x_k|x_{k-1}), marginalizing out x_{k-1}.

**Q:** Why can a recursive Bayesian filter discard all past raw measurements z_{1:k-1} and still be optimal?

**A:** Because the posterior p(x_{k-1}|z_{1:k-1}) is a sufficient statistic — under the Markov/conditional-independence assumptions it summarizes everything the past data say about the current and future state, so it serves as next step's prior with no information loss.

**Q:** Qualitatively, what happens to the spread (uncertainty) of the belief during predict versus during update, and why?

**A:** Predict spreads the belief out (uncertainty grows) because the motion model is itself uncertain; update contracts it (uncertainty shrinks) because a measurement injects new information.

**Q:** Robot in cells {A,B,C}; predicted prior is (0.41, 0.36, 0.23) and the sensor likelihood is (0.1, 0.8, 0.1). After the Bayesian update, which cell holds the most belief and roughly what probability?

**A:** Cell B, with probability ≈ 0.82 (unnormalized 0.288 / evidence 0.352).

**Q:** A colleague proposes keeping ALL past measurements in a growing batch and re-solving the full joint posterior every time a new return arrives — 'more data, more optimal.' Relative to recursive Bayesian filtering, is this more accurate, and what is its real cost?
  a) More accurate, and worth the extra compute
  b) Same accuracy, but cost grows unboundedly with time
  c) Less accurate because old data is stale

**A:** Same accuracy, but cost grows unboundedly with time — The whole value proposition of recursion is constant cost with no loss of optimality — provided the model assumptions hold.

**Q:** For general (non-Gaussian, nonlinear) models the predict and update steps are stated easily but are intractable to compute exactly. Which two specific operations blow up, and how do later filters (KF/EKF/UKF/PF) respond?

**A:** The Chapman–Kolmogorov integral in predict and the evidence normalizer (and posterior) in update are generally not computable in closed form. The later filters are all tractable approximations of these same two steps: the Kalman filter assumes everything is linear-Gaussian so they become matrix algebra; EKF linearizes; UKF uses deterministic sigma-point sampling; particle filters use Monte-Carlo samples.


## State-space models and the Gaussian assumptions (F, H, Q, R)

*The linear-Gaussian state-space model is the specific instance of the Bayesian filter that the Kalman filter solves exactly. Two equations — x_k = F x_{k-1} + w (dynamics) and z_k = H x_k + v (measurement) — with w~N(0,Q) and v~N(0,R). This node defines every symbol (x, P, F, H, Q, R) and explains why linearity + Gaussianity make predict and update closed-form.*

In n1-bayes we built the universal predict–update loop and saw that, in general, its two integrals are intractable. This node introduces the one set of modelling choices under which they become *exact, closed-form matrix operations* — the **linear-Gaussian state-space model**. Master this and the Kalman filter (later nodes) is just bookkeeping.

**The state vector $x$ and its covariance $P$.** The *state* $x \in \mathbb{R}^n$ is the minimal list of numbers needed to describe the target for prediction purposes — typically position and velocity, e.g. $x = [p_x, v_x, p_y, v_y]^\top$ for a 2-D constant-velocity target ($n=4$). Because we are uncertain, in n1-bayes the belief was a whole distribution. The Gaussian assumption lets us summarize that distribution with just two objects: the **mean** $\hat{x}$ (our best estimate) and the **covariance matrix** $P \in \mathbb{R}^{n\times n}$ (our uncertainty). $P$'s diagonal entries are the variances of each state component; its off-diagonals encode *correlations* — e.g. how much a position error tends to coincide with a velocity error. A Gaussian $\mathcal{N}(\hat x, P)$ is fully specified by these two, so the entire infinite-dimensional belief collapses to $n + n(n+1)/2$ numbers ($n$ for the mean, $n(n+1)/2$ for the symmetric covariance). This is the practical miracle that makes the filter run in constant memory.

**The dynamics equation.** The motion model from n1-bayes, $p(x_k\mid x_{k-1})$, is specialized to a *linear* map plus *additive Gaussian* noise:
$$ x_k = F\,x_{k-1} + w_k, \qquad w_k \sim \mathcal{N}(0, Q). $$
- $F \in \mathbb{R}^{n\times n}$ is the **state-transition matrix**: the deterministic physics of how the state evolves over one time step $\Delta t$. For constant velocity, position advances by velocity$\times\Delta t$ and velocity is unchanged, so per coordinate $F = \begin{bmatrix} 1 & \Delta t \\ 0 & 1\end{bmatrix}$.
- $w_k$ is the **process noise**, with covariance matrix $Q \in \mathbb{R}^{n\times n}$. $Q$ is the humility term: it admits that real targets accelerate, turn, and gust in ways $F$ doesn't capture. Larger $Q$ = "trust the model less," which makes the filter more responsive but jumpier. Tuning $Q$ is a recurring craft (n3, n7).

**The measurement equation.** Likewise the likelihood $p(z_k\mid x_k)$ becomes:
$$ z_k = H\,x_k + v_k, \qquad v_k \sim \mathcal{N}(0, R). $$
- $z_k \in \mathbb{R}^m$ is the measurement (e.g. just a position fix, $m=2$).
- $H \in \mathbb{R}^{m\times n}$ is the **measurement (observation) matrix**: it maps the full state into the space the sensor actually reports. A position-only sensor on the $[p,v]$ state uses $H = [1\ \ 0]$ per coordinate — it *selects* position and is blind to velocity. $H$ is generally not square: the sensor sees fewer quantities ($m$) than the state carries ($n$), which is *why* we need a filter to infer the unobserved components (velocity) from the observed ones over time.
- $v_k$ is the **measurement noise**, covariance $R \in \mathbb{R}^{m\times m}$ — the sensor's own error statistics, often from a datasheet (e.g. range accuracy). Larger $R$ = "trust the sensor less."

**Reading the four matrices as a sentence.** $F$ says *how the world moves*, $Q$ says *how surprising its motion is*, $H$ says *what the sensor sees*, $R$ says *how noisy that seeing is*. The relative size of $Q$ vs $R$ alone determines the filter's whole personality — it sets how much the next measurement is allowed to move the estimate (this becomes the Kalman gain $K$ in n2-gaussians/n2-1dkf). *(practical)* Veteran trackers say "you don't tune a Kalman filter, you tune the ratio $Q/R$."

**Why linear + Gaussian = closed form.** Two facts of Gaussian algebra do all the work. (1) A linear transform of a Gaussian is Gaussian: if $x \sim \mathcal{N}(\hat x, P)$ then $Fx + w \sim \mathcal{N}(F\hat x,\ FPF^\top + Q)$. So the Chapman–Kolmogorov *integral* of n1-bayes becomes two matrix formulas: the predicted mean $\hat x^- = F\hat x$ and predicted covariance $P^- = FPF^\top + Q$. (2) The product of two Gaussians (prior $\times$ likelihood, i.e. the Bayes update) is again Gaussian, so the update also stays in the family. Because the belief never leaves the Gaussian family, the filter only ever has to track $(\hat x, P)$ — never an arbitrary curve. **The Kalman filter is the linear-Gaussian special case of the recursive Bayesian filter, and it is exact within that case.** When reality is *not* linear or *not* Gaussian, these conveniences fail and we reach for EKF/UKF/PF (n4) — each a different patch over exactly this gap.

**A worked numerical example.** 1-D constant-velocity target, $\Delta t = 1$ s, state $x=[p, v]^\top$. Prior $\hat x = [0\ \text{m},\ 1\ \text{m/s}]^\top$, $P = \mathrm{diag}(1, 1)$. With $F = \begin{bmatrix}1 & 1\\ 0 & 1\end{bmatrix}$ and $Q = \begin{bmatrix}0.1 & 0\\ 0 & 0.1\end{bmatrix}$:
Predicted mean $\hat x^- = F\hat x = [0 + 1,\ 1]^\top = [1, 1]^\top$ — exactly what intuition says (move 1 m/s for 1 s). Predicted covariance:
$FPF^\top = \begin{bmatrix}1&1\\0&1\end{bmatrix}\begin{bmatrix}1&0\\0&1\end{bmatrix}\begin{bmatrix}1&0\\1&1\end{bmatrix} = \begin{bmatrix}2&1\\1&1\end{bmatrix}$, then add $Q$: $P^- = \begin{bmatrix}2.1&1\\1&1.1\end{bmatrix}$. Two things to notice: position variance grew from 1 to 2.1 (uncertainty *spread* during predict, just as the discrete robot example flattened in n1-bayes), and an off-diagonal $1$ appeared where there was none — predicting through $F$ *created correlation* between position and velocity, because uncertain velocity now contaminates future position. That induced correlation is precisely the channel through which a later *position* measurement will let the filter correct its *velocity* estimate via $H$. The update step that consumes this $P^-$ is n2's subject.

*(historical and accurate)* Rudolf E. Kálmán published this formulation — "A New Approach to Linear Filtering and Prediction Problems" — in the *Transactions of the ASME—Journal of Basic Engineering*, vol. 82, ser. D, pp. 35–45, in 1960. Stanley F. Schmidt at NASA's Ames Research Center saw, during a visit by Kálmán to Ames around 1960, that the filter could be *linearized about a reference trajectory* to handle the *nonlinear* navigation equations of the Apollo program. That linearization technique is what we now call the **extended Kalman filter (EKF)** — the variant eventually flown on Apollo 11 (we cover it in n4). (Schmidt separately also developed the distinct *Schmidt–Kalman* or *consider* filter, which accounts for the uncertainty of nuisance/bias parameters without estimating them; do not confuse it with the EKF.) *(historical and accurate)* A note on notation: Kálmán's 1960 paper did **not** use the symbols $F, H, Q, R$ — it wrote the transition operator as $\Phi$ and used different conventions throughout. The now-standard $F, H, Q, R, P$ notation you are learning was popularized by later tracking and control texts (e.g. Gelb's *Applied Optimal Estimation*, 1974, and the NASA-era engineering literature), which is why nearly every modern tracking text uses them.


**Q:** Write the two equations that define a linear-Gaussian state-space model (dynamics and measurement), including the noise terms and their distributions.

**A:** Dynamics: x_k = F x_{k-1} + w_k with w_k ~ N(0, Q). Measurement: z_k = H x_k + v_k with v_k ~ N(0, R).

**Q:** What does the covariance matrix P represent, and what do its off-diagonal entries encode specifically?

**A:** P is the uncertainty of the state estimate; its diagonal entries are the variances of each state component and its off-diagonal entries encode the correlations between components (e.g. position–velocity).

**Q:** What is the role of the measurement matrix H, and why is it usually non-square?

**A:** H maps the full state into the quantities the sensor actually reports (z = Hx). It is usually non-square (m×n with m<n) because the sensor observes fewer quantities than the state carries — e.g. a position-only sensor cannot see velocity — which is exactly why a filter is needed to infer the unobserved components over time.

**Q:** In a linear-Gaussian model, which covariance describes uncertainty in the motion model, and what does increasing it tell the filter to do?

**A:** Q, the process-noise covariance, describes uncertainty in the motion model (unmodeled accelerations/turns); increasing Q tells the filter to trust the model/prediction less and weight new measurements more.

**Q:** In a linear-Gaussian model, which covariance describes the sensor's own error, and what does increasing it tell the filter to do?

**A:** R, the measurement-noise covariance, describes the sensor's own error; increasing R tells the filter to trust the sensor less and weight the model/prediction more.

**Q (cloze):** Predicted mean: $\hat x^- = ____$.   Predicted covariance: $P^- = ____$.

**A:** Predicted mean: $\hat x^- = **F x̂**$.   Predicted covariance: $P^- = **F P Fᵀ + Q**$.

**Q:** Why does the linear + Gaussian combination make the Bayesian predict and update steps closed-form, where general models are intractable?

**A:** Because of two closure properties of Gaussians under linear operations: a linear transform of a Gaussian is Gaussian (so the Chapman–Kolmogorov integral collapses to x̂⁻=Fx̂, P⁻=FPFᵀ+Q), and the product of two Gaussians (prior × likelihood) is again Gaussian (so the Bayes update stays Gaussian). The belief therefore never leaves the Gaussian family and is fully described by just (x̂, P), turning intractable integrals into matrix algebra.

**Q:** 1-D CV target, Δt=1, F=[[1,1],[0,1]], prior P=diag(1,1), Q=diag(0.1,0.1). Compute P⁻ = FPFᵀ + Q and explain the newly appeared off-diagonal term.

**A:** FPFᵀ = [[2,1],[1,1]], so P⁻ = [[2.1,1],[1,1.1]]. The off-diagonal 1 is a position–velocity correlation created by prediction: because velocity is uncertain, propagating it through F contaminates future position, coupling the two. This induced correlation is the channel through which a later position measurement can correct the velocity estimate.

**Q:** Two engineers describe the Kalman filter. A: 'It's a general-purpose optimal Bayesian filter for any tracking problem.' B: 'It's the exact solution to the recursive Bayesian filter only in the linear-Gaussian special case.' Who is right, and what concretely breaks A's claim?
  a) A — it works for any tracking problem
  b) B — exact only in the linear-Gaussian case
  c) Both are equivalent statements

**A:** B — exact only in the linear-Gaussian case — Framing the KF as a special case (not a universal tool) is what makes the rest of the ladder make sense.

**Q:** Give the publication venue and year of Kalman's foundational paper, and name the filter variant Stanley Schmidt produced by linearizing it for the Apollo program.

**A:** Kalman's 'A New Approach to Linear Filtering and Prediction Problems' appeared in the Transactions of the ASME—Journal of Basic Engineering, vol. 82, pp. 35–45, in 1960. By linearizing the filter about a reference trajectory to handle Apollo's nonlinear navigation equations, Stanley F. Schmidt at NASA Ames produced what is now called the extended Kalman filter (EKF), the variant flown on Apollo 11.


## From moving average to EWMA: the recursive, noise-reducing seed

We have a noisy stream of measurements of something that is roughly constant — the weight of a newborn read off a wobbly scale, the temperature of a room, the position of a stationary beacon seen through sensor jitter. Each reading $z_k$ is the truth $x$ plus a dollop of zero-mean noise: $z_k = x + w_k$. Any single reading is untrustworthy, but the noise averages out. The oldest, most intuitive estimator is the **simple moving average (SMA)**: average the last $N$ readings, $\hat{x}_k = \tfrac{1}{N}\sum_{i=0}^{N-1} z_{k-i}$. If the noise on each sample has variance $\sigma^2$ and the samples are independent, the variance of the average is $\sigma^2/N$ — the noise shrinks by a factor of $N$, and the standard deviation by $\sqrt{N}$. Averaging *works*; it is the simplest instance of the deep principle that combining independent noisy observations reduces uncertainty.

But the SMA has three flaws that motivate everything that follows. **First, it has a hard memory boundary.** It weights the last $N$ samples equally and everything before them zero — a sharp cliff that throws away information and makes the estimate jerk when an old sample falls out of the window. **Second, it is laggy.** If the true value is slowly drifting (the baby is actually gaining weight), an equal-weight average effectively centered on the *middle* of the window systematically trails the present by about $N/2$ samples (its group delay is $(N-1)/2$). **Third, and most damning for an online tracker, it is not recursive in a bounded way.** To compute $\hat{x}_k$ you must store the last $N$ raw samples and re-sum (or carefully add-the-new/subtract-the-old). Memory and bookkeeping grow with the window. A tracker that must run forever on a small radar processor cannot afford a buffer that scales with how long it has been running.

The fix is to make recent data matter more than old data, *smoothly*, and to fold the entire past into a single running number. This is the **exponentially weighted moving average (EWMA)**, also historically called the *geometric moving average* because the weights fall off in a geometric progression. Pick a smoothing factor $\alpha \in (0,1]$ and write the update as:

$$ \hat{x}_k = \hat{x}_{k-1} + \alpha\,(z_k - \hat{x}_{k-1}) = (1-\alpha)\,\hat{x}_{k-1} + \alpha\,z_k. $$

Read the first form aloud: *the new estimate is the old estimate plus a fraction $\alpha$ of the error between what we just measured and what we predicted.* That residual $z_k - \hat{x}_{k-1}$ is the seed of the **innovation** $\nu$ you will meet in every filter hereafter, and the fraction $\alpha$ is the seed of the **Kalman gain** $K$. The EWMA is, structurally, a one-state Kalman filter with a frozen gain.

Unrolling the recursion shows where the name comes from. Substituting repeatedly, $\hat{x}_k = \alpha z_k + \alpha(1-\alpha)z_{k-1} + \alpha(1-\alpha)^2 z_{k-2} + \cdots$. The weight on the sample $i$ steps ago is $\alpha(1-\alpha)^i$ — geometrically decaying, summing to 1, never quite reaching zero. There is no cliff: old data fades, it is not amputated. The whole infinite past is compressed into the single number $\hat{x}_{k-1}$.

**Worked example.** Take $\alpha = 0.5$ and a true value $x = 100$. Start the estimate cold at $\hat{x}_0 = 100$ (or anywhere — it washes out). Suppose the next three noisy readings are $z_1 = 104,\ z_2 = 97,\ z_3 = 101$. Then $\hat{x}_1 = 100 + 0.5(104-100) = 102$; $\hat{x}_2 = 102 + 0.5(97-102) = 99.5$; $\hat{x}_3 = 99.5 + 0.5(101-99.5) = 100.25$. Each reading nudges the estimate by half its surprise; the estimate is far smoother than the raw $104,97,101$.

**Choosing $\alpha$ trades responsiveness against smoothing.** Large $\alpha$ (near 1) trusts the newest measurement, tracks change fast, but barely filters noise (at $\alpha=1$ the estimate *is* the latest reading). Small $\alpha$ (near 0) heavily averages, suppresses noise, but lags badly on real change. A useful rule of thumb: an EWMA with factor $\alpha$ has roughly the same noise-averaging "effective memory" as an SMA of span $N \approx (2-\alpha)/\alpha$ (equivalently $\alpha \approx 2/(N+1)$), so $\alpha \approx 2/\alpha$ behaves like $N \approx 2/\alpha$ for small $\alpha$ — e.g. $\alpha=0.1$ behaves like averaging about 19 samples, but with smooth decay and $O(1)$ memory.

The crucial conceptual leap: $\alpha$ here is **fixed by hand**. The filter has no idea whether it is currently confident or just starting up; it applies the same gain forever. That rigidity is the limitation the next rungs attack. The EWMA also assumes the truth is **stationary** — constant in the mean. The moment the target actually *moves* with a velocity, a position-only EWMA will lag forever, because it has no concept of the rate of change. *(Historical and accurate)* S. W. Roberts introduced this estimator to statistical process control in his 1959 Technometrics paper "Control Chart Tests Based on Geometric Moving Averages" (vol. 1, no. 3, pp. 239–250), where he called it the geometric moving average and showed by simulation that it detects small drifts in a process mean faster than an equal-weight moving average — the same responsiveness-vs-smoothing trade we just derived.


**Q:** Write the EWMA update in its 'prediction + correction' form, naming the smoothing factor.

**A:** x̂_k = x̂_{k−1} + α (z_k − x̂_{k−1}), where α ∈ (0,1] is the smoothing factor and (z_k − x̂_{k−1}) is the residual.

**Q:** By what factor does averaging N independent samples (each noise variance σ²) reduce the variance of the estimate, and by what factor the standard deviation?

**A:** Variance drops by 1/N (to σ²/N); standard deviation drops by 1/√N.

**Q:** In the unrolled EWMA, what is the weight placed on the measurement taken i steps in the past?

**A:** α(1−α)^i — a geometrically decaying weight; the weights sum to 1.

**Q:** Which behavior corresponds to a LARGE α (near 1) versus a SMALL α (near 0) in an EWMA?

**A:** correct; incorrect — that describes small α; incorrect — that describes large α; correct

**Q:** Name the single most important advantage of the EWMA over a simple moving average for an online tracker that must run indefinitely.

**A:** It is bounded-recursive: it folds the entire past into one running number (O(1) memory), versus the SMA which must buffer the last N raw samples.

**Q:** A position-only EWMA tracks a target that is actually moving at a constant velocity. Why does the estimate lag forever no matter how you tune α, and what is the structural fix the next rung introduces?

**A:** The EWMA models the truth as stationary (constant mean) — it has no state for rate of change, so against a ramping true position its correction never catches up to the systematic motion; it perpetually trails. The fix is to add a velocity state and let the residual correct both position and velocity (the alpha-beta / g-h filter).

**Q (cloze):** S. W. ____ introduced the EWMA in his ____ Technometrics paper, calling it the ____ moving average.

**A:** S. W. **Roberts** introduced the EWMA in his **1959** Technometrics paper, calling it the **geometric** moving average.


## The alpha-beta (g-h) filter: inferring hidden velocity from residuals

The position-only EWMA failed against a moving target because it had nowhere to store *how fast the target is moving*. The remedy is to enlarge the state from a single number (position $x$) to a pair (position $x$ and velocity $v$), and to use a tiny physics model — constant velocity — to predict forward between measurements. This gives the **alpha-beta filter**, known equivalently as the **g-h filter** (engineers writing $g$ for $\alpha$ and $h$ for $\beta$). It is the smallest possible tracker that estimates a *hidden* quantity — velocity — that no sensor directly reports.

The rhythm is **predict, then correct**, the same two-beat heartbeat that runs through every filter in this course. Suppose measurements arrive every $\Delta t$ seconds. Holding velocity constant, we *predict* where the target will be:

$$ \hat{x}^- = \hat{x} + \Delta t\,\hat{v}, \qquad \hat{v}^- = \hat{v}. $$

Then a measurement $z$ of position arrives, and we form the **residual** (the prediction's surprise):

$$ r = z - \hat{x}^-. $$

Here is the key idea that the EWMA could not express. A single position residual carries information about *two* things at once. If the target is consistently measured ahead of where we predicted, that is evidence both that our position estimate is low **and** that our velocity estimate is too small. So we split the correction with two gains:

$$ \hat{x} = \hat{x}^- + \alpha\,r, \qquad \hat{v} = \hat{v}^- + \frac{\beta}{\Delta t}\,r. $$

The position gain $\alpha$ behaves exactly like the EWMA factor — it pulls the position estimate a fraction of the way toward the measurement. The velocity gain $\beta$ is the genuinely new machinery: it lets a *position* error nudge the *velocity* estimate. The $1/\Delta t$ converts the position residual (in metres) into a velocity correction (in metres/second), since a sustained position error of $r$ over time $\Delta t$ looks like a velocity discrepancy of $r/\Delta t$. This is the embryonic form of the Kalman filter's ability to update *unobserved* states through their correlation with observed ones — the cross-coupling that the covariance matrix $P$ will later make rigorous.

**Worked example.** A target is at true position 100 m moving at 10 m/s; measurements come every $\Delta t = 1$ s. We pick $\alpha = 0.5,\ \beta = 0.2$ and start *deliberately wrong* with $\hat{x}=100,\ \hat{v}=0$ to watch velocity get learned from residuals. Truth after one second is 110 m; say the measurement is $z_1 = 109$ (noise of $-1$). Predict: $\hat{x}^- = 100 + 1\cdot 0 = 100$, $\hat{v}^-=0$. Residual: $r = 109 - 100 = 9$. Correct: $\hat{x} = 100 + 0.5\cdot 9 = 104.5$; $\hat{v} = 0 + (0.2/1)\cdot 9 = 1.8$ m/s. Notice the filter has begun to infer motion — velocity jumped from 0 toward positive — purely from a *position* residual. Next step, truth is 120 m, $z_2 = 121$. Predict: $\hat{x}^- = 104.5 + 1\cdot 1.8 = 106.3$; residual $r = 121 - 106.3 = 14.7$; correct $\hat{x} = 106.3 + 0.5\cdot14.7 = 113.65$, $\hat{v} = 1.8 + 0.2\cdot14.7 = 4.74$ m/s. Velocity keeps climbing toward the true 10 m/s; the position estimate is closing the gap. Run it a dozen steps and both lock on. The filter *learned a quantity it never measured.*

**How do you choose the gains?** Not freely. The full necessary-and-sufficient stability region (for a discrete constant-velocity α-β filter) is $0 < \alpha < 2$ and $0 < \beta < 4 - 2\alpha$, i.e. $4 - 2\alpha - \beta > 0$ with positive gains; in practice one usually stays in the more conservative, non-oscillatory subregion $0 < \alpha < 1,\ 0 < \beta \le 2$. Within that region, two classic tunings dominate. The **Benedict-Bordner** filter minimizes the transient response to a maneuver for a given amount of steady-state noise, and ties the gains by $\beta = \alpha^2/(2-\alpha)$. The **critically-damped (fading-memory)** filter sets $\alpha = 1-\theta^2$ and $\beta = (1-\theta)^2$ for a single memory parameter $\theta \in (0,1)$, giving a smooth non-oscillatory response governed by one knob. *(Historical and accurate)* T. R. Benedict and G. W. Bordner published "Synthesis of an Optimal Set of Radar Track-While-Scan Smoothing Equations" in the IRE Transactions on Automatic Control, vol. 7, no. 4, pp. 27–32 (July 1962); they used a calculus-of-variations argument to derive exactly the $\beta = \alpha^2/(2-\alpha)$ coupling for track-while-scan radar — two years after Kálmán's 1960 paper but reflecting the independent track-while-scan smoothing tradition.

**The limitation that breaks the alpha-beta filter** is the very thing that made the EWMA brittle, now sharpened: the gains are **constant**. They do not know whether the track is newborn and uncertain (where you want large gains to converge fast) or mature and confident (where you want small gains to reject noise). Worse, $\alpha$ and $\beta$ are *guessed* or hand-tuned; they encode an implicit, unstated belief about how noisy the sensor is and how much the target maneuvers, but the filter never represents that belief explicitly, so it cannot adapt when conditions change. *(Practical)* A constant-gain alpha-beta filter behaves like cruise control with a fixed aggressiveness: fine on a steady highway, but it overshoots on a sudden hill and dawdles on a gentle one, because it has no gauge of its own current confidence. To make the gains *self-adjust* — large when uncertain, small when confident — we need to track uncertainty as a first-class quantity. That is the leap to representing belief as a probability distribution, which the next rung builds with Gaussians.


**Q:** What is the other common name for the alpha-beta filter, and what do the two letters stand for in it?

**A:** The g-h filter; g corresponds to α (position gain) and h to β (velocity gain).

**Q:** In the alpha-beta velocity correction v̂ = v̂⁻ + (β/Δt)·r, why is the residual r divided by Δt?

**A:** r is a position error (metres); a sustained position error of r built up over time Δt corresponds to a velocity discrepancy of r/Δt, so dividing by Δt converts the position residual into the correct units (m/s) for a velocity correction.

**Q:** Conceptually, how can a measurement of POSITION alone update the estimate of VELOCITY, which is never directly measured?

**A:** Because position and velocity are coupled through the constant-velocity prediction: if the target is repeatedly measured ahead of (or behind) the predicted position, that residual is evidence the velocity estimate is too low (or too high). β routes a fraction of the position residual into the velocity state, inferring the hidden quantity from its effect on the observed one.

**Q:** State the Benedict-Bordner coupling between β and α.

**A:** β = α² / (2 − α).

**Q (cloze):** α = ____ and β = ____.

**A:** α = **1 − θ²** and β = **(1 − θ)²**.

**Q:** What is the fundamental limitation of the alpha-beta filter that the Kalman filter will overcome, and why does it matter operationally?

**A:** Its gains α, β are constant — fixed by hand and never adapting. A real track is very uncertain when newborn (wants large gains to converge fast) and confident when mature (wants small gains to reject noise), but a fixed-gain filter cannot tell which regime it is in, because it never represents its own uncertainty explicitly. The Kalman filter tracks uncertainty (covariance P) as a first-class state and recomputes the gain every step from it.

**Q:** State the binding stability constraint on the alpha-beta gains (the outer boundary of the stability region), with the positivity bounds.

**A:** 4 − 2α − β > 0, together with α > 0 and β > 0 (full region 0 < α < 2, 0 < β < 4 − 2α). The product 4 − 2α − β > 0 is the constraint that keeps the filter from diverging.

**Q:** Start an alpha-beta filter at x̂=100, v̂=0, with α=0.5, β=0.2, Δt=1 s. The first position measurement is z=109. Compute the updated x̂ and v̂.

**A:** Predict: x̂⁻=100+1·0=100, v̂⁻=0. Residual r=109−100=9. Update: x̂=100+0.5·9=104.5; v̂=0+(0.2/1)·9=1.8 m/s.


## Fusing two Gaussians = Bayes; the Kalman gain as optimal interpolation

The alpha-beta filter stalled because it had no explicit notion of *how confident it currently is*. The cure is to stop representing belief as a single number and start representing it as a **probability distribution** — and for reasons of both mathematical convenience and the Central Limit Theorem, we choose the **Gaussian**. A Gaussian is fully described by two numbers: a mean $\mu$ (our best estimate) and a variance $\sigma^2$ (our uncertainty). A *small* variance is a tall narrow bell — high confidence. A *large* variance is a broad flat bell — low confidence. Once uncertainty is a number we carry around, the filter can finally answer the question alpha-beta couldn't: *how much should I trust this new measurement versus my prior belief?*

Set up the canonical fusion problem. You hold a prior belief about a scalar quantity: a Gaussian with mean $\mu_1$ and variance $\sigma_1^2$. A sensor delivers a measurement, itself a Gaussian with mean $\mu_2$ and variance $\sigma_2^2$ (the measurement-noise variance). The two are independent estimates of the *same* truth. What single Gaussian best combines them? Bayes' rule says the posterior is proportional to the **product** of the two Gaussian densities. A small, beautiful piece of algebra — multiply two exponentials-of-quadratics and complete the square — yields another Gaussian, with

$$ \mu = \frac{\sigma_2^2\,\mu_1 + \sigma_1^2\,\mu_2}{\sigma_1^2 + \sigma_2^2}, \qquad \frac{1}{\sigma^2} = \frac{1}{\sigma_1^2} + \frac{1}{\sigma_2^2}. $$

Three facts in those two lines drive the entire Kalman filter. **(1) Gaussians are closed under multiplication** — fusing two Gaussians gives a Gaussian, so the filter can recurse forever without the belief degenerating into some intractable shape. This closure is *the* reason the Kalman filter is finite and exact. **(2) Precisions add.** Define **precision** as inverse variance, $\tau = 1/\sigma^2$ — literally "how sharp is my knowledge." The fused precision is $\tau = \tau_1 + \tau_2$: combining evidence always *increases* sharpness. The posterior variance is smaller than either input variance — you are never less certain after incorporating an independent measurement. **(3) The mean is a precision-weighted average** — each estimate is weighted by the *other's* variance, i.e. by its own precision. The estimate you trust more (smaller variance, larger precision) pulls the answer toward itself.

Now rewrite the mean to expose the structure that the rest of the course is built on. Algebraically the fusion mean equals

$$ \mu = \mu_1 + K\,(\mu_2 - \mu_1), \qquad K = \frac{\sigma_1^2}{\sigma_1^2 + \sigma_2^2}. $$

This is *exactly* the EWMA's "old estimate + gain × residual" form — but now the gain $K$ is **derived, not guessed**. $K$ is the **Kalman gain**, and it is an *optimal interpolation factor* living in $[0,1]$ that slides the answer between prior and measurement. Read its two limits, and the whole filter becomes intuitive. If the measurement is very noisy ($\sigma_2^2 \to \infty$), then $K \to 0$: ignore the measurement, keep the prior. If the prior is very uncertain ($\sigma_1^2 \to \infty$, e.g. a brand-new track), then $K \to 1$: throw away the prior, snap to the measurement. The gain is the *ratio of what you do not know to the total you do not know* — prior variance over total variance. This is precisely the self-adjusting behavior the alpha-beta filter lacked: a newborn track gets a near-1 gain and converges fast; a mature, confident track gets a near-0 gain and rejects noise.

**Worked example.** Your prior says a position is at $\mu_1 = 10$ m with $\sigma_1^2 = 4$ (so $\sigma_1 = 2$ m). A GPS fix reads $\mu_2 = 16$ m with $\sigma_2^2 = 1$ (so $\sigma_2 = 1$ m — twice as precise in standard deviation, four times in variance). Gain: $K = 4/(4+1) = 0.8$. Fused mean: $\mu = 10 + 0.8\,(16-10) = 14.8$ m — pulled most of the way toward the trustworthy GPS. Fused variance: $1/\sigma^2 = 1/4 + 1/1 = 1.25$, so $\sigma^2 = 0.8$, $\sigma = 0.894$ m. The posterior ($\sigma=0.894$ m) is *sharper than the better of the two inputs* ($\sigma=1$ m) — fusing two independent estimates beats either one alone. Equivalently $\sigma^2 = (1-K)\sigma_1^2 = 0.2\cdot 4 = 0.8$: the gain also tells you how much the variance shrank.

**Why this is the heart of everything.** The Kalman filter is, in one sentence, *this Gaussian fusion applied recursively, with a prediction step inserted between fusions to move the belief forward in time and inflate its variance.* The cross-coupling that let alpha-beta infer velocity will reappear as off-diagonal covariance terms, turning the scalar $K$ into a matrix that routes a measurement of one state into corrections of others. *(Historical and accurate)* That a minimum-variance estimate of a Gaussian quantity coincides with its posterior mean has deep roots in Carl Friedrich Gauss, who in *Theoria Motus Corporum Coelestium* (1809) systematized the method of least squares while computing the orbit of the dwarf planet Ceres — which Piazzi had discovered on 1 January 1801 and then lost behind the Sun. Gauss's predicted position let astronomers recover Ceres in late 1801 — arguably the first great data-fusion-for-tracking success, a century and a half before Kalman gave least-squares estimation a recursive form. *(Metaphorical)* Think of two witnesses describing where a thrown ball landed: a sharp-eyed one and a fuzzy one. You don't average their guesses equally — you lean toward the sharp-eyed witness in exact proportion to how much sharper their vision is. $K$ is precisely that lean.


**Q:** When you multiply two Gaussian densities (Bayesian fusion of two independent estimates of one quantity), how do the precisions (inverse variances) combine?

**A:** They add: 1/σ² = 1/σ₁² + 1/σ₂². The fused precision is the sum, so the posterior is always sharper than either input.

**Q:** Give the scalar Kalman gain as an interpolation factor between a prior (variance σ₁²) and a measurement (variance σ₂²), and state its range.

**A:** K = σ₁² / (σ₁² + σ₂²), which lies in [0,1] — prior variance over total variance.

**Q:** Interpret the two limits of the scalar Kalman gain: a very noisy measurement (σ₂²→∞) and a very uncertain prior (σ₁²→∞).

**A:** Noisy measurement σ₂²→∞ ⇒ K→0: ignore the measurement, keep the prior. Uncertain prior σ₁²→∞ ⇒ K→1: discard the prior, snap to the measurement. K is the ratio of unknown-prior to total-unknown.

**Q:** Prior: μ₁=10 m, σ₁²=4. Measurement: μ₂=16 m, σ₂²=1. Compute the Kalman gain, the fused mean, and the fused variance.

**A:** K = 4/(4+1) = 0.8. Fused mean μ = 10 + 0.8(16−10) = 14.8 m. Fused variance: 1/σ² = 1/4 + 1/1 = 1.25 ⇒ σ² = 0.8 (equivalently (1−K)σ₁² = 0.2·4 = 0.8).

**Q:** After fusing two independent Gaussian estimates of the same quantity, the posterior variance is...

**A:** correct — precisions add, so 1/σ² > both 1/σᵢ², making σ² < both; incorrect — variances are not averaged; precisions add; incorrect — independent evidence reduces, never increases, uncertainty; incorrect — it is strictly smaller than even the smaller input

**Q:** Why is the Gaussian assumption (rather than some other distribution) what makes the Kalman filter exact and able to recurse indefinitely?

**A:** Gaussians are closed under both multiplication (fusion) and linear transformation (prediction): the product of two Gaussians is Gaussian, and a linear map of a Gaussian is Gaussian. So the belief stays a Gaussian — two numbers — forever, instead of degenerating into an intractable shape, letting the filter recurse exactly and finitely.

**Q:** Show that the Gaussian-fusion mean μ = (σ₂²μ₁ + σ₁²μ₂)/(σ₁²+σ₂²) is identical to the 'prior + gain × residual' form μ₁ + K(μ₂−μ₁). What is K?

**A:** Expand μ₁ + K(μ₂−μ₁) with K = σ₁²/(σ₁²+σ₂²): = μ₁(1−K) + Kμ₂ = μ₁·σ₂²/(σ₁²+σ₂²) + μ₂·σ₁²/(σ₁²+σ₂²) = (σ₂²μ₁ + σ₁²μ₂)/(σ₁²+σ₂²). Identical. So K = σ₁²/(σ₁²+σ₂²).


## The scalar Kalman filter: predict inflates, update shrinks, steady state = EWMA

We now have the two ingredients we need and can assemble the **scalar Kalman filter** — the full predict/update loop on a single state with explicit uncertainty. From the Gaussian-fusion rung we know how to *combine* a prior belief with a measurement optimally. What was missing is a way to move the belief *forward in time* between measurements, and crucially, to account for the fact that the world drifts in ways we cannot perfectly predict. That is the job of the **prediction** step. The full filter alternates two operations forever: **predict** (advance the state through a motion model, and grow the uncertainty), then **update** (fuse the incoming measurement, and shrink the uncertainty). One sentence to memorize: **prediction inflates variance; update shrinks it.** Tracking is the perpetual tension between those two.

Fix the scalar setup. The state is one number $\hat{x}$ with variance $P$ (we now write $P$ for the state variance, foreshadowing the covariance matrix). The motion model says the truth evolves as $x_k = f\,x_{k-1} + w$, where $f$ is a scalar transition (often $f=1$ for a constant quantity) and $w$ is **process noise** with variance $Q$ — this $Q$ is our humility, the admission that the model is imperfect and the truth wanders. The sensor reports $z_k = h\,x_k + \nu$, with $h$ a scalar measurement scaling (often $h=1$) and $\nu$ measurement noise of variance $R$.

**Predict step.** Push the mean through the model and inflate the variance:
$$ \hat{x}^- = f\,\hat{x}, \qquad P^- = f^2 P + Q. $$
The $f^2 P$ term is how variance transforms through a scaling (variance scales by the square of a linear factor); the $+Q$ term is the new uncertainty injected because the world drifted unpredictably since the last measurement. Without $Q$, a filter run open-loop would falsely believe it gets more and more certain while actually losing track — the classic **filter divergence**. With $f \ge 1$ prediction *always grows* $P$ (and even for $f<1$ the $+Q$ keeps it from collapsing): you know less about *now* than you knew about *then*, because time has passed.

**Update step.** A measurement $z$ arrives. Form the **innovation** $\nu = z - h\hat{x}^-$ (the surprise), with **innovation variance** $S = h^2 P^- + R$ (how surprised you *expected* to be: predicted uncertainty seen through the sensor, plus sensor noise). The **Kalman gain** is the predicted uncertainty mapped to measurement space, divided by total innovation variance:
$$ K = \frac{P^- h}{S} = \frac{P^- h}{h^2 P^- + R}. $$
Then fuse:
$$ \hat{x} = \hat{x}^- + K\,\nu, \qquad P = (1 - Kh)\,P^-. $$
With $h=1$ this is *exactly* the Gaussian fusion of the previous rung — $K = P^-/(P^-+R)$ is prior-variance-over-total — confirming the prediction step simply supplied a freshly inflated prior $P^-$ to be fused. The update *always shrinks* $P$: since $Kh\in[0,1]$, $(1-Kh)P^- < P^-$. Every measurement makes you more certain; every tick of waiting makes you less.

**Worked example (h = f = 1, a noisy constant).** Track a constant true value $x=100$. Sensor noise $R = 4$; process noise $Q = 0.1$ (we believe the value is nearly constant, with tiny drift). Start uncertain: $\hat{x}_0 = 0,\ P_0 = 1000$. Measurement $z_1 = 98$. Predict: $\hat{x}^- = 0,\ P^- = 1000 + 0.1 = 1000.1$. Innovation $\nu = 98 - 0 = 98$; $S = 1000.1 + 4 = 1004.1$; gain $K = 1000.1/1004.1 = 0.996$. Update: $\hat{x} = 0 + 0.996\cdot 98 = 97.6$; $P = (1-0.996)\cdot 1000.1 = 3.98$. In one step the near-1 gain *snapped* the estimate from 0 to 97.6 and collapsed the variance from 1000 to about 4 — exactly the newborn-track behavior we wanted and that fixed-gain filters could never produce. Step 2, $z_2 = 101$: predict $P^- = 3.98 + 0.1 = 4.08$; $S = 4.08+4 = 8.08$; $K = 4.08/8.08 = 0.505$; $\hat{x} = 97.6 + 0.505(101-97.6) = 99.3$; $P = (1-0.505)\cdot 4.08 = 2.02$. The gain has already fallen from 0.996 to 0.505 — the filter is *automatically becoming conservative as it gains confidence.* Run it further and $K$ settles.

**The punchline: steady state equals an EWMA.** With $f=h=1$ and constant $Q,R$, the variance recursion $P^- = P + Q$ then $P = (1-K)P^-$ converges to a fixed point $P_\infty$, and therefore the gain converges to a constant $K_\infty$. At that point the update $\hat{x} = \hat{x}^- + K_\infty(z-\hat{x}^-)$ is *literally an EWMA with $\alpha = K_\infty$.* The whole ladder closes: the EWMA we started with is the steady-state limit of the Kalman filter, and the Kalman filter is the EWMA whose gain we *derived from the noise statistics* and that *self-tunes during the transient*. The steady-state gain depends only on the ratio $Q/R$ — how much the world moves relative to how noisy the sensor is. Large $Q/R$ (twitchy target, clean sensor) ⇒ large $K_\infty$ ⇒ responsive. Small $Q/R$ (steady target, noisy sensor) ⇒ small $K_\infty$ ⇒ heavy smoothing. *(Historical and accurate)* Rudolf E. Kálmán published "A New Approach to Linear Filtering and Prediction Problems" in the *Transactions of the ASME—Journal of Basic Engineering*, vol. 82, ser. D, pp. 35–45 (March 1960; DOI 10.1115/1.3662552). Its decisive novelty over Wiener's earlier frequency-domain filter was exactly this *recursive, state-space, time-domain* form — a covariance that propagates by a difference equation — which is why it ran on digital computers and naturally handles nonstationary statistics where Wiener's spectral-factorization approach did not. *(Practical)* This Q/R intuition is the single most useful tuning lever you will ever hold: when a real filter lags maneuvers, you raise Q; when it chatters on noise, you raise R (or lower Q). You will formalize this with NIS/NEES two rungs ahead.


**Q:** In the scalar Kalman filter, what happens to the state variance P during the PREDICT step versus the UPDATE step?

**A:** Predict inflates P (P⁻ = f²P + Q grows it); update shrinks P (P = (1−Kh)P⁻ reduces it). Prediction adds uncertainty as time passes; measurement removes uncertainty.

**Q:** Write the scalar predict equations for the mean and variance, naming each term.

**A:** x̂⁻ = f·x̂ (push mean through transition f); P⁻ = f²P + Q (variance scales by f², plus process-noise variance Q).

**Q:** Define the innovation ν and the innovation variance S in the scalar filter.

**A:** Innovation ν = z − h·x̂⁻ (the measurement minus its prediction — the 'surprise'). Innovation variance S = h²P⁻ + R (predicted state variance mapped through the sensor, plus measurement-noise variance R).

**Q:** What is the role of the process-noise variance Q, and what fails if you set it to zero for a quantity that actually drifts?

**A:** Q is the injected uncertainty per predict step — the model's humility about unmodeled drift. With Q=0 on a drifting quantity, P shrinks toward zero, the gain K→0, and the filter stops listening to measurements while the truth walks away: filter divergence (overconfidence / the filter 'goes to sleep').

**Q:** Why does the scalar Kalman filter at steady state become an EWMA, and what single ratio sets the steady-state gain?

**A:** With f=h=1 and constant Q,R, the variance recursion has a fixed point P∞, so K converges to a constant K∞; then x̂ = x̂⁻ + K∞(z−x̂⁻) is exactly an EWMA with α=K∞. The steady-state gain is governed by the ratio Q/R: large Q/R ⇒ large K∞ (responsive); small Q/R ⇒ small K∞ (heavy smoothing).

**Q:** Scalar KF, f=h=1, R=4, Q=0.1. State x̂=0, P=1000. Measurement z=98. Compute P⁻, K, the updated x̂, and updated P.

**A:** Predict: P⁻ = 1000 + 0.1 = 1000.1. S = 1000.1 + 4 = 1004.1. K = 1000.1/1004.1 ≈ 0.996. Update: x̂ = 0 + 0.996·98 ≈ 97.6. P = (1−0.996)·1000.1 ≈ 3.98.

**Q:** On the very first update of a freshly initialized track (huge P), the Kalman gain K is approximately...

**A:** correct — huge P⁻ makes K = P⁻/(P⁻+R) ≈ 1; incorrect — a brand-new track has no trustworthy prior; incorrect — the gain depends on the P/R ratio, not a fixed split; incorrect — it is well-defined from the first update

**Q (cloze):** R. E. ____ published the recursive filter in ____; its advantage over Wiener was its ____-domain, state-space, recursive form.

**A:** R. E. **Kálmán** published the recursive filter in **1960**; its advantage over Wiener was its **time**-domain, state-space, recursive form.


## The multivariate Kalman filter: x, P, FPFᵀ+Q, S, K=PHᵀS⁻¹

The scalar Kalman filter tracks one number. A real target lives in many dimensions at once — position *and* velocity *and* acceleration, in *x*, *y*, *z*. The leap to the **multivariate Kalman filter** is conceptually small (the same predict-inflates / update-shrinks heartbeat) but it unlocks the single most important capability of the whole framework: the **covariance matrix** $P$ does not just store *how uncertain* each state is, it stores *how the uncertainties are correlated* — and those correlations are what let a measurement of one state correct another. This is the alpha-beta filter's velocity-from-position trick, now made exact and automatic.

Replace the scalar state with a vector $\mathbf{x}$. For a 2D constant-velocity (CV) target, $\mathbf{x} = [p_x,\ p_y,\ v_x,\ v_y]^\top$. Replace the scalar variance $P$ with the **covariance matrix** $P$, an $n\times n$ symmetric matrix whose diagonal entries are the per-state variances and whose off-diagonals are the covariances *between* states. A nonzero $\mathrm{Cov}(p_x, v_x)$ entry literally says "my position error and my velocity error tend to move together" — and that entry is the channel through which a position measurement will adjust the velocity estimate. The scalars $f,h,Q,R$ become matrices $F,H,Q,R$:

- $F$ — **state-transition matrix**: how the state evolves over $\Delta t$ in one step. For 2D CV, $p_x \leftarrow p_x + \Delta t\,v_x$, velocity unchanged, giving $F = \begin{bmatrix}1&0&\Delta t&0\\0&1&0&\Delta t\\0&0&1&0\\0&0&0&1\end{bmatrix}$.
- $H$ — **measurement matrix**: maps state to what the sensor sees. A position-only sensor measures $p_x,p_y$ but not velocity: $H = \begin{bmatrix}1&0&0&0\\0&1&0&0\end{bmatrix}$.
- $Q$ — **process-noise covariance** ($n\times n$): unmodeled accelerations; injected each predict.
- $R$ — **measurement-noise covariance** (size = #measurements): sensor error correlations.

**Predict step** (note how the scalar $f^2P$ generalizes — variance transforms by sandwiching $P$ between $F$ and its transpose):
$$ \hat{\mathbf{x}}^- = F\hat{\mathbf{x}}, \qquad P^- = F P F^\top + Q. $$
The term $FPF^\top$ is the heart of multivariate prediction. Crucially, *even if $P$ starts diagonal* (no correlations), $FPF^\top$ generates off-diagonal terms: pushing position forward by $\Delta t\,v$ entangles position uncertainty with velocity uncertainty. The filter *manufactures the very correlations* it will later exploit. That is why a position-only sensor can sharpen a velocity estimate — prediction creates the $p$–$v$ covariance, and update reads it back.

**Update step** (the matrix forms you will use for the rest of your life):
$$ \boldsymbol{\nu} = \mathbf{z} - H\hat{\mathbf{x}}^- \quad(\text{innovation}), \qquad S = H P^- H^\top + R \quad(\text{innovation covariance}), $$
$$ K = P^- H^\top S^{-1} \quad(\text{Kalman gain}), $$
$$ \hat{\mathbf{x}} = \hat{\mathbf{x}}^- + K\boldsymbol{\nu}, \qquad P = (I - KH)\,P^-. $$
Every symbol is the matrix sibling of a scalar you already know. $S = HP^-H^\top + R$ is "predicted uncertainty seen through the sensor, plus sensor noise" — the scalar $h^2P^-+R$. $K = P^-H^\top S^{-1}$ is "predicted uncertainty mapped to measurement space, normalized by total innovation" — the scalar $P^-h/S$, with the division replaced by $S^{-1}$. And $K$ is an $n\times m$ matrix: it maps an $m$-vector of measurement surprise into an $n$-vector of state correction, so the *off-diagonal* entries of $K$ are exactly what let a position innovation correct velocity. *(Practical)* $S^{-1}$ is the only matrix inverse in the simple update form, and its size is the number of *measurements*, not states — so even a 9-state filter with a 2D position sensor inverts only a $2\times 2$. Memorize $S$: it reappears as the gating statistic ($\nu^\top S^{-1}\nu$, the squared Mahalanobis distance) and the consistency check (NIS) in later rungs.

**Worked 2D constant-velocity example.** Let $\Delta t = 1$ s. Take a state $\hat{\mathbf{x}}^- = [0,\,0,\,1,\,0]^\top$ (at origin, moving $+1$ m/s in $x$) after a predict, with — for arithmetic clarity — a predicted covariance $P^-$ that has position variance 10 on $p_x$ and $p_y$, velocity variance 1 on $v_x,v_y$, and a manufactured position-velocity covariance of 2 on the $(p_x,v_x)$ and $(p_y,v_y)$ pairs. A position sensor with $R = \mathrm{diag}(4,4)$ reports $\mathbf{z} = [3,\,0]^\top$. Innovation: $\boldsymbol{\nu} = [3,0]^\top - [0,0]^\top = [3,0]^\top$. Innovation covariance (the $p_x$ channel): $S_{xx} = P^-_{p_x p_x} + R_{xx} = 10 + 4 = 14$. Gain for the $x$-channel: the position row is $K_{p_x} = P^-_{p_x p_x}/S_{xx} = 10/14 = 0.714$, and — here is the magic — the *velocity* row is $K_{v_x} = P^-_{v_x p_x}/S_{xx} = 2/14 = 0.143$. Update: position $p_x = 0 + 0.714\cdot 3 = 2.14$ m; velocity $v_x = 1 + 0.143\cdot 3 = 1.43$ m/s. **A pure position measurement just raised the velocity estimate** — because $P^-$ carried a positive $p_x$–$v_x$ covariance, the filter inferred that being measured ahead of prediction means the target is also faster than thought. This is the alpha-beta intuition, now derived from first principles rather than hand-tuned, and generalizing to any number of states and cross-correlations.

This matrix filter is the workhorse the entire rest of the course stands on. Its assumptions — *linear* $F$ and $H$, *Gaussian* $Q$ and $R$ — are exactly the cracks that the EKF, UKF, and particle filter (next ladder) will pry open when targets turn, sensors measure range-and-bearing, or posteriors go multimodal. *(Historical and accurate)* Stanley F. Schmidt of NASA Ames Research Center is generally credited with the first major aerospace application: after R. E. Kálmán visited Ames in the fall of 1960, Schmidt recognized the filter's fit to Apollo trajectory estimation and worked out the *nonlinear* adaptation — linearizing about the current estimate — that is now known as the **Extended Kalman Filter** (the Smith, Schmidt & McGee 1962 NASA report). Separately, the term "Schmidt-Kalman filter" refers to a *different* contribution of his: the reduced-order "consider" filter, which accounts for nuisance parameters such as biases in the covariance without estimating them. The Apollo Guidance Computer's 15-bit fixed-point arithmetic could not run the naive covariance recursion stably; MIT's James E. Potter solved this with *square-root* filtering (1962), propagating a Cholesky factor of $P$ to preserve positive-definiteness — the first of the numerical-robustness fixes (Joseph form, square-root/UD factorization) you will meet at the consistency rung.


**Q:** Write the multivariate predict equations for the mean and covariance.

**A:** x̂⁻ = F·x̂ and P⁻ = F·P·Fᵀ + Q, where F is the state-transition matrix and Q the process-noise covariance.

**Q:** Write the innovation covariance S and the Kalman gain K in matrix form, naming each factor.

**A:** S = H·P⁻·Hᵀ + R (predicted covariance through the measurement matrix H, plus measurement-noise covariance R). K = P⁻·Hᵀ·S⁻¹ (predicted covariance mapped to measurement space, normalized by S).

**Q:** What does an off-diagonal entry of the covariance matrix P represent, and why is it operationally critical in tracking?

**A:** It is the covariance between two states (e.g. position and velocity) — how their errors correlate. It is critical because a nonzero cross-covariance is the channel through which a measurement of one state (position) corrects another, unmeasured state (velocity); without it, the filter could never infer hidden states.

**Q:** Even when P starts perfectly diagonal (no correlations), the predicted P⁻ = FPFᵀ + Q develops off-diagonal terms. Why, and why does this matter for a position-only sensor?

**A:** Because F couples states — pushing position forward by Δt·v makes the new position depend on velocity, so the FPFᵀ sandwich mixes their variances into a position-velocity covariance. This matters because that manufactured cross-covariance is exactly what the update step reads back: it lets a position-only measurement sharpen the velocity estimate. Prediction creates the correlation, update exploits it.

**Q:** Predicted state x̂⁻=[0,0,1,0] (px,py,vx,vy), with P⁻ giving variance 10 on px, 1 on vx, and covariance 2 between px and vx. Position sensor R=diag(4,4) reports z=[3,0]. Compute the x-channel innovation, the px and vx gain entries, and the updated px and vx.

**A:** Innovation νx = 3 − 0 = 3. Sxx = 10 + 4 = 14. K_px = 10/14 ≈ 0.714; K_vx = 2/14 ≈ 0.143. Updated px = 0 + 0.714·3 ≈ 2.14 m; updated vx = 1 + 0.143·3 ≈ 1.43 m/s. A position measurement raised the velocity estimate via the px–vx covariance.

**Q:** Write the 2D constant-velocity state-transition matrix F for state [px, py, vx, vy] with timestep Δt.

**A:** F = [[1,0,Δt,0],[0,1,0,Δt],[0,0,1,0],[0,0,0,1]] — position gets Δt times velocity, velocity unchanged.

**Q:** In a 9-state filter (3D position/velocity/acceleration) observed by a 2D position sensor, what size matrix must be inverted to compute K, and why?

**A:** correct — only S⁻¹ is inverted, and S is m×m where m = #measurements (2); incorrect — P is never inverted in the standard form; incorrect — K is not inverted; it is computed from S⁻¹; incorrect — S⁻¹ is required

**Q:** Who is credited with the first major aerospace application of the Kalman filter, and for what program?

**A:** Stanley F. Schmidt at NASA Ames, for Apollo trajectory/navigation estimation, after Kálmán visited Ames in fall 1960. His nonlinear adaptation (linearizing about the current estimate) is the origin of the Extended Kalman Filter.

**Q:** What numerical technique, and by whom, made the Kalman covariance recursion run stably on the Apollo Guidance Computer's 15-bit fixed-point arithmetic?

**A:** Square-root filtering by James E. Potter (MIT Instrumentation Laboratory, 1962): propagate a Cholesky 'square-root' factor of the covariance P instead of P itself, which preserves positive-definiteness and effectively doubles the precision.


## Innovations, NIS/NEES, divergence, Joseph form, and tuning Q and R

*A Kalman filter reports both an estimate and a covariance P claiming how good that estimate is. Consistency is the question of whether P is honest. We test honesty with the filter's own running scorecard — the innovation sequence — via NIS (chi-squared, dim z dof), and against ground truth via NEES (dim x dof). When P shrinks faster than the truth warrants, the filter grows overconfident, gates out good measurements, and diverges. We harden the update arithmetic with the Joseph form and re-inflate P by tuning Q (model ignorance) and R (sensor noise) until the scorecard reads honest.*

## The estimate is only half the answer

By this rung you can run the multivariate Kalman filter: predict $\hat{x}_{k|k-1}=F\hat{x}_{k-1|k-1}$, push the covariance forward $P_{k|k-1}=FP_{k-1|k-1}F^\top+Q$, form the innovation $\nu=z-H\hat{x}_{k|k-1}$ with covariance $S=HP_{k|k-1}H^\top+R$, compute the gain $K=P_{k|k-1}H^\top S^{-1}$, and update. The filter hands you back two things at every step: a state estimate $\hat{x}$ **and** a covariance $P$ that advertises how trustworthy that estimate is. Here is the uncomfortable truth that this node is about: *nothing so far forces $P$ to tell the truth.* The recursion will dutifully produce a small, confident-looking $P$ whether or not the estimate deserves that confidence. The arithmetic of $FPF^\top+Q$ and $(I-KH)P$ does not check itself against reality. A filter can be wrong **and** sure of itself — and that combination is the single most dangerous failure mode in tracking, because every downstream decision (which measurement to associate, whether to keep a track alive) trusts $P$.

**Consistency** is the property that $P$ is honest: the filter's claimed uncertainty matches its actual error. Formally, an estimator is consistent when (i) the estimation error is zero-mean, $E[x-\hat{x}]=0$, and (ii) the actual mean-square error matches the reported covariance, $E[(x-\hat{x})(x-\hat{x})^\top]=P$. A filter that satisfies these is *credible*: when it says "I'm accurate to 5 m, one-sigma," it really is. The whole point of this node is to give you the diagnostics that detect dishonesty and the tools that restore it. *(metaphorical)* Think of $P$ as a weather forecaster's confidence. A forecaster who says "90% chance of rain" should be right about 90% of the time over many such forecasts. If it rains only 50% of the time after such claims, the forecaster is overconfident — not necessarily wrong on any single day, but systematically miscalibrated. Consistency testing is exactly calibration testing for a filter.

## The innovation sequence is the filter's self-graded scorecard

We cannot usually see the true state $x$, so we cannot directly measure $x-\hat{x}$. But we *can* see something almost as good: the innovation $\nu_k = z_k - H\hat{x}_{k|k-1}$, the gap between what we measured and what we predicted we'd measure. The innovation is observable at every step using only data the filter already has. And theory makes a sharp, falsifiable promise about it. If the filter's model ($F,H,Q,R$) is correct, the innovation sequence is **zero-mean white noise** with a known covariance $S_k = HP_{k|k-1}H^\top + R$. Two claims hidden in there: each innovation is zero-mean Gaussian with covariance $S$, *and* successive innovations are uncorrelated (white). This is not an approximation — for a correctly-modelled linear-Gaussian system it is exact, and it is the deepest practical consequence of the Kalman filter's optimality. *(historical and accurate)* Rudolf E. Kálmán's 1960 paper *"A New Approach to Linear Filtering and Prediction Problems"* (Trans. ASME, J. Basic Engineering, vol. 82, Series D, pp. 35–45) derived the filter via orthogonal projection in Hilbert space: the optimal estimate is the one whose residual is orthogonal to — uncorrelated with — all past data. The explicit reframing of this in terms of a *white innovation process* (and the very term "innovation") came later, with Thomas Kailath's *"An Innovations Approach to Least-Squares Estimation, Part I"* (IEEE Trans. Automatic Control, vol. AC-13, no. 6, pp. 646–655, Dec. 1968), which whitens the observations and recovers the Kalman recursions from that white sequence. Either way the practical moral is the same: whiteness *is* optimality. If your innovations are correlated, there is still information in them you haven't extracted, so the filter is leaving accuracy on the table.

This gives us a test that needs no ground truth. Normalize the innovation by its own claimed covariance and square it:

$$\text{NIS}_k \;=\; \nu_k^\top S_k^{-1}\nu_k.$$

If the filter is consistent, $\text{NIS}_k$ follows a **chi-squared distribution with $n_z = \dim(z)$ degrees of freedom**, so $E[\text{NIS}_k] = n_z$. This is the Normalized Innovation Squared. It is the workhorse of *online* consistency monitoring because everything in it is computable in real operation. The logic: $S$ is the filter's claim about how big $\nu$ should typically be. Dividing $\nu$ by $S$ (in the Mahalanobis sense) converts that claim into a unitless score that should average $n_z$. If your NIS systematically runs *above* $n_z$, the innovations are bigger than $S$ predicted — $S$ is too small — the filter is **overconfident**. If NIS runs *below* $n_z$, the filter is **underconfident** (pessimistic), claiming more uncertainty than it has.

### Worked example: a 2-D position sensor

Suppose $z$ is a 2-D Cartesian position, so $n_z=2$ and $E[\text{NIS}]=2$. Take a single step where the predicted measurement is $H\hat{x}_{k|k-1}=(100,\,50)$ m, the actual measurement is $z=(103,\,46)$ m, so $\nu=(3,\,-4)^\top$. Suppose the filter claims $S=\begin{psmallmatrix}4&0\\0&4\end{psmallmatrix}$ m$^2$ (one-sigma of 2 m per axis, uncorrelated). Then $S^{-1}=\tfrac14 I$ and
$$\text{NIS}=\tfrac14(3^2+4^2)=\tfrac{25}{4}=6.25.$$
The 95% two-sided acceptance region for a $\chi^2_2$ variable is $[0.051,\,7.378]$ (from the inverse CDF). $6.25$ sits inside, just barely — one such step is unremarkable. But suppose instead the filter had grown smug and claimed $S=\begin{psmallmatrix}1&0\\0&1\end{psmallmatrix}$ (one-sigma of 1 m). The *same* innovation now scores $\text{NIS}=3^2+4^2=25$, far outside $7.378$. The data hasn't changed; only the filter's self-confidence has — and the test catches it. Over many steps you'd average the NIS: a clean run hovers near 2; a run averaging, say, 6 is screaming that $S$ is roughly three times too small.

## When ground truth is available: NEES

NIS tests the *measurement-space* claim $S$. In simulation, where we know the true $x$, we can test the far more demanding *state-space* claim — that $P$ itself is honest, including the velocity and other unmeasured components NIS never touches. Define the **Normalized Estimation Error Squared**:

$$\text{NEES}_k \;=\; (x_k-\hat{x}_{k|k})^\top P_{k|k}^{-1} (x_k-\hat{x}_{k|k}).$$

For a consistent filter $\text{NEES}_k \sim \chi^2_{n_x}$ with $n_x=\dim(x)$ degrees of freedom, so $E[\text{NEES}_k]=n_x$. NEES is strictly stronger than NIS — a filter can pass NIS (its measured components look calibrated) yet fail NEES (its velocity covariance is a fantasy), because NIS only ever sees the part of the error that lands in measurement space. The price is that NEES needs the true $x$, so it is a *design-time / Monte-Carlo* tool, not an online one. *(practical)* The standard tuning ritual: run $N$ Monte-Carlo trials of your simulator, average NEES across runs at each time, and check the average against tightened bounds. For $N$ independent runs and state dimension $n_x$, the averaged NEES $\overline{\text{NEES}} = \tfrac1N\sum_i \text{NEES}_i$ satisfies $N\,\overline{\text{NEES}}\sim\chi^2_{Nn_x}$, so the two-sided 95% acceptance interval is $[\,F^{-1}(0.025,Nn_x)/N,\;F^{-1}(0.975,Nn_x)/N\,]$.

### Worked example: averaged NEES bounds

Take a constant-velocity tracker in 2-D, $x=(p_x,v_x,p_y,v_y)$, so $n_x=4$ and a single-run NEES should average 4 with 95% bounds $[0.484,\,11.14]$ — a wide band, so a single run tells you almost nothing. Now average $N=50$ runs. The bounds tighten dramatically to $[\,F^{-1}(0.025,200)/50,\;F^{-1}(0.975,200)/50\,]=[3.25,\,4.82]$, still centred on 4. If your 50-run averaged NEES sits at, say, 9, that is unambiguous: more than double the upper bound, the filter is grossly overconfident — its $P$ is far too small for the errors it actually makes. The averaging is what converts a noisy per-step statistic into a sharp verdict; this is why consistency tuning is done over Monte-Carlo ensembles, not single runs.

## Divergence: the failure NIS/NEES are warning you about

Why obsess over an honest $P$? Because a dishonest, shrinking $P$ drives the filter into **divergence** — the estimate wandering arbitrarily far from truth with no self-correction. The mechanism is a vicious cycle. Recall the gain $K=PH^\top S^{-1}$: when $P$ is small, $K$ is small, so the filter weights new measurements lightly and clings to its prediction. If $P$ is *erroneously* small (overconfident), the filter ignores measurements that are actually correcting it. Its error grows while its claimed $P$ stays tiny, so it ignores measurements even harder. *(metaphorical)* This is the **"smug filter"**: so convinced of its own accuracy that it dismisses all contrary evidence, and the more wrong it gets the more it dismisses. In a multi-target tracker the consequence is concrete and brutal: an overconfident $P$ yields a tiny validation gate (next node), so the true measurement falls *outside* the gate, the track is never corrected, and it drifts off and dies.

*(historical and accurate)* R. J. Fitzgerald's 1971 paper *"Divergence of the Kalman Filter"* (IEEE Trans. Automatic Control, vol. 16, no. 6, pp. 736–747) is the classic anatomy. Fitzgerald distinguished **apparent divergence** — error grows to a large but *bounded* steady state, typically from modelling error like an unmodelled acceleration — from **true divergence**, where the mean-square error grows *without bound*. His key, sobering result: increasing the assumed process noise $Q$ can cure apparent divergence but may fail to cure true divergence. The lesson for us: divergence is usually a *modelling* sin (the filter's $F,Q$ don't match the target's real dynamics), and the cure is to be honest about what you don't know — which is what $Q$ encodes.

## Two fixes: harder arithmetic (Joseph) and honester noise (Q, R)

There are two distinct ways $P$ goes wrong, and two distinct fixes.

**Fix 1 — numerical: the Joseph form.** The convenient update $P_{k|k}=(I-KH)P_{k|k-1}$ is a *simplification that is only algebraically valid when $K$ is exactly the optimal gain.* It involves the subtraction $(I-KH)$, and subtraction of nearly-equal floating-point quantities loses precision and destroys the symmetry and positive-definiteness $P$ must have as a covariance. A $P$ that has drifted non-symmetric or acquired a negative eigenvalue can make the filter blow up. The **Joseph stabilized form** repairs this:

$$P_{k|k} \;=\; (I-KH)\,P_{k|k-1}\,(I-KH)^\top \;+\; K\,R\,K^\top.$$

It costs an extra matrix multiply but buys two things. First, it is a sum of two terms each of the form $A\,(\cdot)\,A^\top$ with $P_{k|k-1}$ and $R$ both positive-definite, so the result is *structurally* symmetric positive-semidefinite — round-off can't make it indefinite. Second — and this is the deeper point — it is valid for **any** gain $K$, not only the optimal one. So it correctly propagates covariance when you deliberately use a suboptimal gain (consider states, gated/fading-memory filters) or when $K$ is computed imperfectly. *(historical and accurate)* The form is named for Peter D. Joseph and appears in R. S. Bucy and P. D. Joseph, *Filtering for Stochastic Processes with Applications to Guidance* (Interscience, New York, 1968). The optimal-gain shortcut is the special case where, substituting $K=PH^\top S^{-1}$, the cross terms collapse and Joseph reduces to $(I-KH)P$ — but lean on the shortcut and round-off eventually bites.

**Fix 2 — statistical: tune $Q$ and $R$.** If NIS/NEES say the filter is overconfident, the cure is to put *more* uncertainty into the model. $R$ is the measurement-noise covariance — in principle knowable from the sensor's datasheet or calibration, since it's a property of the hardware. $Q$ is subtler and more important: **$Q$ encodes the filter's ignorance of its own motion model.** A constant-velocity model is a lie — real targets accelerate, turn, maneuver — and $Q$ is the admission of that lie, the injected uncertainty that says "the truth could have drifted from my deterministic prediction by about this much." If $Q$ is too small the filter believes its motion model too literally, $P$ shrinks too fast, and you get the smug-filter divergence above. If $Q$ is too large the filter trusts each measurement nearly completely, tracks noise, and never smooths. *(practical)* The discipline, straight from Bar-Shalom & Fortmann's *Tracking and Data Association* (Academic Press, 1988): drive tuning with the statistics. Run the simulator, plot averaged NEES (and NIS on real data); if it sits above the upper $\chi^2$ bound, increase $Q$ (or $R$); if it sits below, decrease it; iterate until the curve lives inside the band. A common rule of thumb for a CV model is to size the process-noise spectral density so the implied one-sigma velocity change over a scan covers the largest acceleration the target can plausibly produce — $Q$ as a budget for un-modelled maneuver. The destination is not a *small* $P$; it is an *honest* one. A filter with a larger but consistent $P$ is worth more than one with a tiny lying $P$, because only the honest filter's gates, associations, and track-management decisions can be trusted.


**Q:** Write the formula for the Normalized Innovation Squared (NIS) at step k in terms of the innovation ν and innovation covariance S.

**A:** NIS = νᵀ S⁻¹ ν — the innovation normalized (in the Mahalanobis sense) by its own covariance.

**Q:** For a consistent filter, NIS is chi-squared distributed. How many degrees of freedom does it have?

**A:** n_z = dim(z), the dimension of the measurement vector.

**Q:** For a consistent filter, what is the expected value E[NIS]?

**A:** E[NIS] = n_z, the measurement dimension (the mean of a chi-squared variable equals its degrees of freedom).

**Q:** A filter is run in simulation where the true state x is known at every step. You want to verify that the full reported covariance P is honest, including the unmeasured velocity components. Which consistency statistic should you use, NIS or NEES, and why?
  a) NIS, because it needs no ground truth
  b) NEES, because it tests the full P against true error and catches dishonest unmeasured (e.g. velocity) covariance
  c) Either works identically
  d) NIS, because velocity is part of the innovation

**A:** NEES, because it tests the full P against true error and catches dishonest unmeasured (e.g. velocity) covariance — NIS only exercises the part of the error that projects into measurement space (via H); the velocity covariance can be a fantasy and NIS would never know. NEES uses P⁻¹ over the whole state, so it tests the unmeasured components — but it requires the true x, available only in simulation/Monte-Carlo.

**Q:** A 2-D position sensor gives innovation ν = (3, −4)ᵀ m and the filter claims S = diag(1, 1) m². Compute the NIS.

**A:** NIS = νᵀS⁻¹ν = 3² + 4² = 25 (since S⁻¹ = I).

**Q:** That same NIS of 25 is compared against the 95% two-sided χ²₂ acceptance band [0.051, 7.378]. Does the filter pass, and what does the result imply about S?

**A:** It fails — 25 ≫ 7.378, well outside the band. The innovation is far larger than S predicted, so S is too small: the filter is overconfident.

**Q:** An online tracker's running-average NIS sits well ABOVE n_z (e.g. 6 when n_z = 2). Which way should you adjust the noise covariances, and why?

**A:** Increase Q (and/or R). NIS above n_z means the innovations are larger than S = HPHᵀ+R predicted, so S/P is too small (overconfident); inflating Q (model ignorance) and/or R (sensor noise) raises S until the average returns to n_z.

**Q:** Complete the Joseph stabilized covariance update: P_{k|k} = (I − KH) P_{k|k−1} ____ + ____.

**A:** (I − KH)ᵀ + K R Kᵀ. Full form: P_{k|k} = (I−KH) P_{k|k−1} (I−KH)ᵀ + K R Kᵀ.

**Q:** Numerically, what does the Joseph form P = (I−KH)P(I−KH)ᵀ + KRKᵀ guarantee that the simplified update P = (I−KH)P does not?

**A:** It guarantees P stays symmetric and positive-(semi)definite under round-off. Joseph is a sum of two congruences A(·)Aᵀ of positive-definite matrices (P and R), so it is structurally PSD; the simplified form's subtraction (I−KH)P can lose symmetry or pick up a negative eigenvalue and make the filter blow up.

**Q:** For which gains K is the simplified update P = (I−KH)P algebraically correct, and for which is the Joseph form correct?

**A:** The simplified update is correct only when K is the optimal Kalman gain (K = PHᵀS⁻¹); the Joseph form is valid for ANY gain K. So a deliberately suboptimal gain (consider states, gated/fading-memory filters) or an imperfectly computed K requires Joseph.

**Q:** Explain the 'smug filter' divergence cycle: why does an erroneously small P cause the estimate to drift further from truth instead of self-correcting?

**A:** The gain K = PHᵀS⁻¹ scales with P. If P is erroneously small, K is small, so the filter weights new measurements lightly and clings to its prediction — ignoring the very measurements that would correct it. Its true error then grows while claimed P stays tiny, shrinking K further: a positive-feedback loop. (Cure: increase Q so P stops collapsing.)

**Q:** In a Kalman tracker, what does the process-noise covariance Q fundamentally represent, and why must it usually be NONZERO even for a target you believe moves at constant velocity?
  a) Q is the sensor's measurement noise, known from the datasheet
  b) Q encodes model ignorance / un-modelled accelerations; nonzero Q keeps P from collapsing and the filter from going smug
  c) Q is the steady-state Kalman gain
  d) Q only matters for nonlinear filters

**A:** Q encodes model ignorance / un-modelled accelerations; nonzero Q keeps P from collapsing and the filter from going smug — R is the sensor noise (a hardware property); Q is the model-error budget. A CV model omits real acceleration, so Q must absorb that ignorance. Setting Q ≈ 0 makes P shrink without bound, killing the gain and causing divergence — exactly the failure Fitzgerald (1971) analysed and that bumping Q up can cure (for apparent divergence).


## Extended KF: linearization via Jacobians

*The Extended Kalman Filter handles nonlinear dynamics f and measurement models h by linearizing them with first-order Taylor expansions: it replaces F and H with the Jacobians evaluated at the current estimate. Cheap, ubiquitous (Apollo onward), but the linearization is only an approximation and the filter can become overconfident and diverge.*

Everything we have built so far — the predict–update heartbeat, the Gaussian fusion, the matrix Kalman filter with its $\hat x^- = F\hat x$, $P^- = FPF^\top + Q$, gain $K = P^-H^\top S^{-1}$ — rests on one structural assumption: that the dynamics and the measurements are **linear**. The state propagates as $x_{k} = Fx_{k-1}$ and the sensor reports $z = Hx$. Under that assumption a Gaussian stays Gaussian forever (a linear map of a Gaussian is exactly Gaussian), so carrying around just a mean and a covariance is *exact*, not an approximation. The trouble is that almost nothing in the real world is linear. A radar does not measure Cartesian position; it measures **range and azimuth**, $r = \sqrt{x^2+y^2}$, $\theta = \operatorname{atan2}(y,x)$ — manifestly nonlinear functions of the Cartesian state we want to track. A coordinated turn, gravity acting on a ballistic body, a Doppler measurement: all nonlinear. The moment $f$ or $h$ bends, a Gaussian pushed through it comes out *non-Gaussian* (skewed, bent into a banana), and the clean mean/covariance bookkeeping is no longer exact.

The Extended Kalman Filter (EKF) makes the cheapest possible peace with this reality: **linearize and pretend**. We keep the entire Kalman machinery, but at each step we replace the matrices $F$ and $H$ with the local **Jacobians** of the nonlinear functions, evaluated at our current best estimate. Concretely, if the true dynamics are $x_k = f(x_{k-1}) + w$ and the measurement is $z_k = h(x_k) + v$, we take a first-order Taylor expansion of $f$ about the posterior $\hat x_{k-1}$ and of $h$ about the prior $\hat x_k^-$:
$$F_k = \left.\frac{\partial f}{\partial x}\right|_{\hat x_{k-1}}, \qquad H_k = \left.\frac{\partial h}{\partial x}\right|_{\hat x_k^-}.$$
The **state** itself is always propagated through the *true* nonlinear functions — $\hat x_k^- = f(\hat x_{k-1})$ and the predicted measurement is $h(\hat x_k^-)$ — but the **covariance** is propagated through the linearized maps: $P_k^- = F_k P_{k-1} F_k^\top + Q$, $S = H_k P_k^- H_k^\top + R$, $K = P_k^- H_k^\top S^{-1}$. The innovation is still $\nu = z - h(\hat x_k^-)$ — note we subtract the nonlinear prediction, not $H\hat x^-$. Everything else is identical to the matrix KF. The Jacobians are recomputed every cycle because the best linear approximation depends on *where you are*; a tangent line is only locally faithful.

*(historical and accurate)* This is not a textbook abstraction invented for pedagogy. It is the algorithm that flew to the Moon. **Stanley F. Schmidt**, chief of the Dynamic Analysis Branch at NASA's Ames Research Center, encountered Rudolf Kalman's 1960 paper *"A New Approach to Linear Filtering and Prediction Problems"* and recognized that, although Kalman's result was strictly for linear systems, it could be adapted to the violently nonlinear navigation equations of a circumlunar trajectory by linearizing about a reference path. The linearized variant his group developed became known as the **extended** Kalman filter, and a form of it was loaded onto Apollo 11. Schmidt's name is also attached to the **Schmidt–Kalman filter** (the "consider" filter, which carries bias/nuisance states without estimating them, leaving their covariance un-updated), developed during his tenure at Philco's Western Development Laboratory (1962–1966). The EKF's lineage is genuinely the dawn of practical applied estimation.

**Worked example — range/azimuth measurement Jacobian.** Suppose the state is 2-D position and velocity, but the sensor only sees position: $x = [p_x, p_y, \dot p_x, \dot p_y]^\top$, and a radar at the origin returns range $r$ and bearing $\theta$. The measurement function is
$$h(x) = \begin{bmatrix} \sqrt{p_x^2 + p_y^2} \\ \operatorname{atan2}(p_y, p_x) \end{bmatrix}.$$
Let the predicted position be $\hat p_x^- = 30, \hat p_y^- = 40$, so $r = \sqrt{30^2+40^2} = 50$. The Jacobian $H = \partial h/\partial x$ (zero columns for velocity) is
$$H = \begin{bmatrix} p_x/r & p_y/r & 0 & 0 \\ -p_y/r^2 & p_x/r^2 & 0 & 0 \end{bmatrix} = \begin{bmatrix} 0.6 & 0.8 & 0 & 0 \\ -0.016 & 0.012 & 0 & 0 \end{bmatrix}.$$
This $H$ is what enters $S = HP^-H^\top + R$ and $K = P^-H^\top S^{-1}$. Notice that the bearing row scales like $1/r^2$: when the target is far away ($r$ large), a one-radian error in azimuth corresponds to an enormous cross-range distance, and the linear map's fidelity over that span collapses. That is exactly the regime where the EKF gets into trouble.

**Why the EKF can diverge.** Two distinct failure modes, both worth internalizing. First, **bias**: passing the mean through $h$ is not the same as the mean of $h$ pushed through the true curve — for a curved $h$, $E[h(x)] \neq h(E[x])$. The first-order Taylor expansion silently discards that mismatch, so the estimate is systematically off whenever curvature is significant over the spread of the distribution. Second, and more dangerous, **inconsistency / overconfidence**: the covariance $P$ is propagated through the *linearized* map and therefore never "knows" about the linearization error it just committed. The filter reports a $P$ that is too small — it believes itself more certain than it is — so the gain $K$ shrinks, the filter stops listening to measurements, and once it has stopped listening it cannot recover. *(practical)* The canonical cautionary tale is **bearings-only tracking** (an observer measuring only angle to a target, no range): the conventional EKF is notorious for *premature covariance collapse* on the first, poorly observable leg of the geometry and then diverges. This single problem motivated an entire literature of fixes — the iterated EKF (re-linearize the measurement update around the corrected estimate), better initialization, and ultimately the UKF and particle filter you will meet next. The EKF is cheap, it is everywhere, and it is the right first thing to try — but it earns its reputation for divergence precisely because its linearized covariance is blind to its own approximation error.


**Q:** In the Extended Kalman Filter, what mathematical objects replace the matrices F and H of the linear Kalman filter?

**A:** The Jacobians of the nonlinear functions f and h — the matrices of first-order partial derivatives — evaluated at the current state estimate.

**Q:** In the EKF, the state mean is propagated through the TRUE nonlinear functions f and h, but the covariance P is propagated through what?

**A:** Through the linearized maps — i.e. through the Jacobians F_k and H_k (P⁻ = F_k P F_kᵀ + Q, S = H_k P⁻ H_kᵀ + R).

**Q (cloze):** In the EKF measurement update the innovation is ν = z − ____, the nonlinear measurement function applied to the predicted state, NOT the linear form Hx̂⁻.

**A:** In the EKF measurement update the innovation is ν = z − **h(x̂⁻)**, the nonlinear measurement function applied to the predicted state, NOT the linear form Hx̂⁻.

**Q:** Why must the EKF recompute its Jacobians F and H at every time step rather than computing them once?

**A:** Because the best first-order (tangent) approximation of a nonlinear function depends on the operating point; the Jacobian is only locally faithful, so it must be re-evaluated at the current estimate each cycle.

**Q:** First-order linearization corrupts the EKF estimate's MEAN in one specific way. State that mechanism (the inequality involved).

**A:** Bias: for a curved h, E[h(x)] ≠ h(E[x]), so pushing only the mean through h discards the curvature contribution and the estimate is systematically off.

**Q:** First-order linearization corrupts the EKF's reported UNCERTAINTY in one specific way. State that mechanism and its consequence.

**A:** Overconfidence/inconsistency: P is propagated through the linearized map and never accounts for linearization error, so the reported P is too small — the gain K then shrinks and the filter stops trusting measurements.

**Q:** Bearings-only tracking is the classic EKF divergence case. Mechanistically, why does the EKF diverge there even though the state propagation is exact?

**A:** The linearized covariance is blind to its own linearization error, so on the poorly observable first leg P collapses prematurely (the filter becomes overconfident). The gain K then shrinks, the filter stops incorporating new bearings, and once it has stopped listening it cannot correct the error — it diverges.

**Q:** Who adapted Kalman's linear filter to nonlinear navigation for the Apollo program, and what is the resulting algorithm called?

**A:** Stanley F. Schmidt at NASA Ames Research Center; the linearized variant became the Extended Kalman Filter, a form of which was loaded onto Apollo 11.

**Q:** Which statement is TRUE of the EKF? (A) Like the linear KF, a Gaussian pushed through its model stays exactly Gaussian. (B) The EKF's covariance update accounts for linearization error. (C) The EKF replaces F,H with Jacobians but propagates the state mean through the true nonlinear f,h. (D) The EKF requires h to be linear in the state.
  a) A: a Gaussian stays exactly Gaussian
  b) B: covariance accounts for linearization error
  c) C: Jacobians for covariance, true f,h for the state mean
  d) D: requires h linear

**A:** C: Jacobians for covariance, true f,h for the state mean — C is correct. A is false — nonlinearity makes the pushed Gaussian non-Gaussian. B is false — the linearized covariance is exactly blind to linearization error (the source of overconfidence). D is false — the whole point is to handle nonlinear h.


## Unscented KF: the unscented transform and sigma points

*The Unscented Kalman Filter abandons Jacobians. Instead it picks a small deterministic set of sigma points that match the mean and covariance of the state, pushes each one through the TRUE nonlinear function, and recovers the transformed mean and covariance as weighted samples. This unscented transform captures the posterior to second order, is derivative-free, and is typically more accurate and more robust than the EKF for the same cost.*

The EKF's wound is self-inflicted: it linearizes the function and then propagates the covariance through that line, so it can never see how badly the line lied. Julier and Uhlmann's insight was to invert the problem. *It is easier to approximate a probability distribution than it is to approximate an arbitrary nonlinear function.* Rather than fit a tangent plane to $f$ or $h$, choose a handful of carefully placed points that *represent the distribution* of $x$, push each one through the **true, unmodified** nonlinear function, and read off the mean and covariance of the cloud that comes out the other side. No Jacobians. No Taylor series. This is the **unscented transform (UT)**, and a Kalman filter built on it is the **Unscented Kalman Filter (UKF)**.

*(historical and accurate)* The method first appeared in S. J. Julier and J. K. Uhlmann, *"New extension of the Kalman filter to nonlinear systems,"* in *Signal Processing, Sensor Fusion, and Target Recognition VI*, SPIE vol. 3068, pp. 182–193, 1997. *(historical and accurate)* In a first-hand account, Uhlmann has explained that the name "unscented" was deliberately arbitrary — adopted specifically to keep the method from being called the "Uhlmann filter" — and that the word caught his eye from a stick of unscented deodorant sitting on a colleague's desk. The playful name stuck. The scaled version with the now-standard tuning parameters $\alpha, \beta, \kappa$ is due to Wan and Van der Merwe (and Van der Merwe's 2004 dissertation).

**The sigma points.** For an $L$-dimensional state with mean $\hat x$ and covariance $P$, the UT deterministically chooses $2L+1$ **sigma points**: one at the mean, and one pair straddling the mean along each of the $L$ principal axes of the covariance. The spread is governed by a scaling parameter $\lambda = \alpha^2(L+\kappa) - L$. With $\sqrt{(L+\lambda)P}$ a matrix square root (in practice a Cholesky factor) whose columns $S_i$ are the scaled standard-deviation directions:
$$\mathcal{X}_0 = \hat x, \qquad \mathcal{X}_i = \hat x + S_i, \qquad \mathcal{X}_{i+L} = \hat x - S_i, \quad i = 1\dots L.$$
Each point carries two weights — one for reconstructing the **mean**, one for the **covariance**:
$$W_0^{(m)} = \frac{\lambda}{L+\lambda}, \quad W_0^{(c)} = \frac{\lambda}{L+\lambda} + (1-\alpha^2+\beta), \quad W_i^{(m)} = W_i^{(c)} = \frac{1}{2(L+\lambda)}\ (i\ge 1).$$
To propagate, transform every sigma point through the true function, $\mathcal{Y}_i = f(\mathcal{X}_i)$, then recombine: $\hat y = \sum_i W_i^{(m)}\mathcal{Y}_i$ and $P_y = \sum_i W_i^{(c)}(\mathcal{Y}_i - \hat y)(\mathcal{Y}_i - \hat y)^\top + Q$. That weighted-sample mean and covariance *is* the predicted Gaussian. The same trick run through $h$ gives the predicted measurement $\hat z$, the measurement-prediction sample covariance $P_{zz} = \sum_i W_i^{(c)}(\mathcal{Z}_i-\hat z)(\mathcal{Z}_i-\hat z)^\top$, and a state–measurement cross-covariance $P_{xz}$. The innovation covariance is then $S = P_{zz} + R$, the gain is $K = P_{xz}S^{-1}$, and the update is $\hat x = \hat x^- + K\nu$ with $\nu = z - \hat z$, and $P = P^- - KSK^\top$. The structure is still recognizably the Kalman update — but $K$ is now built from sample covariances instead of $PH^\top$.

**The three knobs.** $\alpha$ sets the **spread** of the sigma points around the mean — small $\alpha$ (e.g. $10^{-3}$) keeps the points close so that higher-order nonlinear effects stay local. $\kappa$ is a **secondary** scaling parameter, usually $0$ or $3-L$. $\beta$ injects **prior knowledge of the distribution's shape**; *(practical)* for a Gaussian, $\beta = 2$ is optimal and is the default you should reach for. Note that $W_0^{(c)}$ can be *negative* — that is fine and intended; it is a feature of matching higher moments, not a bug.

**Worked example — why the UT beats the tangent.** Take a scalar nonlinearity $y = x^2$ with $x \sim \mathcal{N}(\mu=2, \sigma^2=1)$. The *true* mean is $E[x^2] = \mu^2 + \sigma^2 = 4 + 1 = 5$. The **EKF** linearizes: $h'(x)=2x$, so it reports $\hat y_{EKF} = h(\mu) = 4$ — it misses the variance contribution entirely and is biased low by exactly $\sigma^2 = 1$. Now the **UT** with $L=1$. Take $\kappa=2$, $\alpha=1$ so $\lambda = 1^2(1+2)-1 = 2$ and $L+\lambda = 3$. Sigma points: $\mathcal{X}_0 = 2$, $\mathcal{X}_{1,2} = 2 \pm \sqrt{3\cdot1} = 2 \pm 1.732$, i.e. $\{2, 3.732, 0.268\}$. Weights: $W_0^{(m)} = 2/3$, $W_{1,2}^{(m)} = 1/6$. Push through $y=x^2$: $\{4, 13.93, 0.0718\}$. Reconstruct: $\hat y = \tfrac{2}{3}(4) + \tfrac{1}{6}(13.93) + \tfrac{1}{6}(0.0718) = 2.667 + 2.322 + 0.012 = 5.0$. The UT recovers the exact mean $5$, while the EKF reported $4$. This is the whole story in one line: the EKF evaluates the function at the mean, the UT evaluates the *mean of the function* — and for quadratic nonlinearity it gets it exactly right.

**Where the UKF stands relative to the EKF.** The UT matches the transformed mean and covariance to **second order** for any nonlinearity (third order for symmetric distributions like the Gaussian), versus the EKF's **first order**. It is **derivative-free** — no hand-derived (and error-prone) Jacobians, which is decisive when $f$ or $h$ is a tangled simulation or a lookup. The computational cost is comparable to the EKF (you evaluate the function $2L+1$ times instead of differentiating it once). The catches: the UT can still fail for *strongly* nonlinear or genuinely multimodal posteriors (it still summarizes everything as a single Gaussian), and a naive covariance update can lose positive-definiteness — which is why square-root UKF formulations propagate the Cholesky factor directly. But as a default upgrade from the EKF, the UKF is usually the right move: same cost, better mean, and a covariance that is far less prone to the optimistic collapse that wrecks the EKF on problems like bearings-only tracking.


**Q:** What is the core idea of the unscented transform — what does it approximate instead of the nonlinear function?

**A:** It approximates the probability distribution: it picks deterministic sigma points matching the mean and covariance, pushes each through the TRUE nonlinear function, and reads off the transformed mean and covariance — no linearization of f or h.

**Q:** For an L-dimensional state, how many sigma points does the standard unscented transform use, and where are they placed?

**A:** 2L+1 points: one at the mean, plus one symmetric pair straddling the mean along each of the L principal axes of the covariance.

**Q (cloze):** The unscented-transform scaling parameter is λ = ____, where L is the state dimension; the sigma-point square-root direction is √((L+λ)P).

**A:** The unscented-transform scaling parameter is λ = **α²(L + κ) − L**, where L is the state dimension; the sigma-point square-root direction is √((L+λ)P).

**Q:** In the unscented transform, which single parameter controls the SPREAD of the sigma points around the mean?

**A:** α — small α keeps the sigma points close to the mean so higher-order nonlinear effects stay local.

**Q:** In the unscented transform, which parameter encodes prior knowledge of the distribution's SHAPE, and what is its optimal value for a Gaussian?

**A:** β encodes prior knowledge of the distribution's shape; for a Gaussian, β = 2 is optimal.

**Q:** In the unscented transform, what is the role of the parameter κ (kappa)?

**A:** κ is a secondary scaling parameter affecting sigma-point spread, usually set to 0 or 3−L.

**Q:** Take y = x², x ~ N(μ=2, σ²=1). The EKF reports ŷ = 4. What is the true mean, and why does the UT recover it where the EKF fails?

**A:** True mean = μ²+σ² = 5. The EKF evaluates the function at the mean, h(μ)=4, discarding the σ² curvature term. The UT pushes sigma points (which carry the spread) through the true x² and averages, so it captures E[h(x)]=5 — it computes the mean of the function, not the function of the mean.

**Q:** To what order does the unscented transform capture the transformed mean/covariance, versus the EKF, and what error-prone step does the UKF eliminate?

**A:** The UT is accurate to second order (third order for symmetric/Gaussian distributions) versus the EKF's first order. The UKF is derivative-free — it eliminates the need to derive and code the Jacobians of f and h.

**Q:** Which statement about the UKF is TRUE? (A) The covariance sigma-point weight W₀⁽ᶜ⁾ must be positive. (B) The UKF requires Jacobians of f and h. (C) The UKF gain is K = P_xz S⁻¹, built from the sample cross-covariance. (D) Like the EKF it linearizes f and h with a Taylor series.
  a) A: W₀⁽ᶜ⁾ must be positive
  b) B: requires Jacobians
  c) C: K = P_xz S⁻¹ from sample cross-covariance
  d) D: linearizes with Taylor series

**A:** C: K = P_xz S⁻¹ from sample cross-covariance — C is correct — the UKF builds K from the sample cross-covariance P_xz (K = P_xz S⁻¹). A is false: W₀⁽ᶜ⁾ can legitimately be negative. B and D are false: the UKF is derivative-free and uses sigma points through the true nonlinearity instead of Taylor linearization.


## Particle filters: non-Gaussian/multimodal posteriors

*Particle filters drop the Gaussian assumption entirely. They represent the posterior as a swarm of weighted random samples (particles), propagate them through the true dynamics, weight them by the measurement likelihood, and resample to kill degenerate particles. This handles multimodal and arbitrarily non-Gaussian posteriors that no single-Gaussian filter can — at the price of needing many particles, and suffering the curse of dimensionality.*

The EKF and UKF share one unbroken assumption with the original Kalman filter: the posterior is a **single Gaussian**, summarized by a mean and a covariance. The UKF propagates that Gaussian more honestly than the EKF, but it still hands you back a Gaussian at the end. Yet many real posteriors are not even close to a single bell. A robot localizing in a symmetric corridor is genuinely **bimodal** — it might be here, or it might be at the mirror-image spot, and the data so far cannot tell. A bearings-only tracker with no range information has a banana-shaped posterior smeared along the line of sight. No mean-and-covariance pair can faithfully describe "two distinct possibilities" or "a long curved ridge." To represent those, we need a representation that can take *any* shape. The **particle filter** uses the most flexible representation there is: a cloud of samples. It is the recursive Bayesian heartbeat of node n1 — predict, then update — but with the posterior density carried as a weighted set of point masses $\{(x^{(i)}, w^{(i)})\}_{i=1}^{N}$ instead of a Gaussian.

The representation is the whole idea: a probability density can be approximated by a swarm of $N$ samples, where the local density of particles (and their weights) encodes the probability mass. Where the true posterior is tall, many high-weight particles pile up; where it is near zero, particles are sparse. As $N \to \infty$ this converges to the true density for *any* shape — multimodal, skewed, banana, whatever — which is exactly what the Gaussian filters cannot do. The machinery for steering this swarm is **importance sampling**: we cannot sample the posterior directly, so we sample from an easier proposal (the simplest choice being the dynamics themselves) and correct the mismatch by reweighting each particle by how well it explains the new measurement.

*(historical and accurate)* The breakthrough that made this practical is **N. J. Gordon, D. J. Salmond, and A. F. M. Smith, *"Novel approach to nonlinear/non-Gaussian Bayesian state estimation,"* IEE Proceedings-F (Radar and Signal Processing), vol. 140, no. 2, pp. 107–113, 1993** — the **bootstrap filter**. Earlier sequential importance sampling schemes had a fatal disease called **weight degeneracy**: after a few steps almost all the weight collapses onto a single particle and every other particle is wasted computation. Gordon, Salmond, and Smith added the missing ingredient — a **resampling** step — and the algorithm became usable. Their paper demonstrated it on a **bearings-only tracking** problem (the very scenario that breaks the EKF) and included schemes for improving the basic algorithm's efficiency.

**The algorithm (Sequential Importance Resampling, SIR / bootstrap).** (1) **Predict**: push every particle through the true dynamics and add a sample of process noise, $x_k^{(i)} = f(x_{k-1}^{(i)}) + w^{(i)}$. The cloud diffuses and bends exactly as the true nonlinear dynamics dictate — no linearization anywhere. (2) **Update**: weight each particle by the measurement likelihood, $w_k^{(i)} \propto w_{k-1}^{(i)}\, p(z_k \mid x_k^{(i)})$, then normalize so $\sum_i w^{(i)} = 1$. Particles that predicted the measurement well get heavy; those that did not get light. (3) **Resample**: draw $N$ new particles *with replacement* from the current set with probability proportional to weight, then reset all weights to $1/N$. High-weight particles are duplicated; low-weight particles die. This concentrates computation where the posterior actually lives and is what cures degeneracy. The state estimate is then any functional of the swarm — typically the weighted mean $\sum_i w^{(i)} x^{(i)}$, though for a bimodal posterior you would report the modes, not the mean (which would sit in the empty valley between them).

**Worked example — degeneracy and the effective sample size.** Suppose after the weighting step we have $N=4$ particles with normalized weights $\{0.97, 0.01, 0.01, 0.01\}$. One particle is doing essentially all the work. We quantify this with the **effective sample size** $N_{\text{eff}} = 1 / \sum_i (w^{(i)})^2$. Here $\sum (w^{(i)})^2 = 0.97^2 + 3(0.01)^2 = 0.9409 + 0.0003 = 0.9412$, so $N_{\text{eff}} = 1/0.9412 \approx 1.06$. Out of four particles we have the statistical power of barely one — catastrophic degeneracy. Contrast a healthy uniform cloud $\{0.25,0.25,0.25,0.25\}$: $\sum w^2 = 4(0.0625)=0.25$, so $N_{\text{eff}} = 1/0.25 = 4 = N$, the maximum. The standard adaptive rule is to **resample only when $N_{\text{eff}}$ drops below a threshold** (commonly $N/2$), which avoids the opposite problem — resampling too often impoverishes the sample by repeatedly duplicating the same few particles. *(practical)* Gordon, Salmond, and Smith's original fix for this **sample impoverishment** was **roughening**: after resampling, add a small jitter of noise to the duplicated particles so the swarm regains diversity instead of collapsing onto identical copies.

**The price: the curse of dimensionality.** Particle filters buy generality with sample count, and that bill grows brutally with state dimension. *(historical and accurate)* This is not folklore — it was made rigorous. **Bengtsson, Bickel, and Li (2008)** and **Snyder, Bengtsson, Bickel, and Anderson, *"Obstacles to High-Dimensional Particle Filtering,"* Monthly Weather Review vol. 136, 2008** proved that to keep the filter from collapsing (the maximum weight tending to 1, i.e. one particle taking over), the required number of particles grows **exponentially** with the effective dimension of the problem. Their analysis shows, for instance, that a 200-dimensional example needs on the order of $10^{11}$ particles to avoid collapse. In a 3-D tracking state a few thousand particles is plenty; in a high-dimensional system (say a geophysical model with thousands of states) no feasible number of particles suffices, and the filter degenerates after a single step. **This is why particle filters have not displaced the Kalman family.** For low-dimensional, strongly non-Gaussian or multimodal problems — robot localization, bearings-only tracking, target acquisition before track is established — the particle filter is the tool that works where the EKF and UKF fail. For high-dimensional, mildly nonlinear, roughly-Gaussian problems, the UKF or even the EKF is far cheaper and just as good. Choosing among EKF, UKF, and PF is therefore not about which is "best" in the abstract; it is about matching the representation to the *shape of your posterior and the dimension of your state*.


**Q:** How does a particle filter represent the posterior distribution, and why does this let it handle shapes the EKF/UKF cannot?

**A:** As a set of weighted random samples (particles) — point masses whose local density and weights encode probability mass. Because samples can cluster into any shape, this represents multimodal, skewed, or banana-shaped posteriors that a single Gaussian (mean + covariance) cannot.

**Q:** In the SIR/bootstrap particle filter, by what quantity is each particle reweighted in the update step?

**A:** By the measurement likelihood p(z_k | x_k⁽ⁱ⁾) — particles whose predicted state explains the measurement well get higher weight; weights are then normalized to sum to 1.

**Q:** What problem does the resampling step solve, and what does resampling do mechanically?

**A:** It solves weight degeneracy (all weight collapsing onto one particle). Mechanically it draws N new particles with replacement, with probability proportional to weight — duplicating high-weight particles and killing low-weight ones — then resets all weights to 1/N.

**Q (cloze):** The effective sample size is N_eff = ____; the common adaptive rule resamples only when N_eff falls below ~N/2.

**A:** The effective sample size is N_eff = **1 / Σ(w⁽ⁱ⁾)²**; the common adaptive rule resamples only when N_eff falls below ~N/2.

**Q:** Four particles have normalized weights {0.97, 0.01, 0.01, 0.01}. Compute N_eff and interpret it.

**A:** Σw² = 0.97² + 3(0.01²) = 0.9409 + 0.0003 = 0.9412, so N_eff = 1/0.9412 ≈ 1.06. Out of 4 particles only ~1 is doing useful work — severe degeneracy, so the filter should resample (or it has already collapsed).

**Q:** Resampling cures degeneracy but introduces 'sample impoverishment.' What is that, and what was Gordon/Salmond/Smith's fix?

**A:** Sample impoverishment is loss of diversity: resampling repeatedly duplicates the same few high-weight particles until the swarm collapses onto identical copies. Their fix was roughening — adding a small jitter of noise to the resampled particles to restore diversity.

**Q:** Why have particle filters NOT replaced the Kalman family despite handling arbitrary posteriors — and who proved the underlying obstacle?

**A:** The curse of dimensionality: to avoid weight collapse (max weight → 1) the number of particles must grow exponentially with the effective state dimension, so high-dimensional problems are infeasible. This was made rigorous by Bengtsson, Bickel & Li (2008) and Snyder, Bengtsson, Bickel & Anderson (2008, 'Obstacles to High-Dimensional Particle Filtering').

**Q:** For which problem is a particle filter the clearly better choice over an EKF/UKF? (A) A 30-state geophysical model that is mildly nonlinear and roughly Gaussian. (B) A robot localizing in a symmetric corridor with a genuinely bimodal posterior. (C) A linear constant-velocity track in low clutter. (D) Any problem, since PFs are universally superior.
  a) A: 30-state mildly-nonlinear Gaussian model
  b) B: robot in symmetric corridor, bimodal posterior
  c) C: linear constant-velocity track
  d) D: any problem

**A:** B: robot in symmetric corridor, bimodal posterior — B is correct — a genuinely bimodal posterior is exactly what a single-Gaussian filter cannot represent and a PF can. A is a curse-of-dimensionality trap (high dimension, Gaussian → use UKF). C is linear/Gaussian → the plain KF is optimal and cheapest. D is false — PFs lose badly in high dimensions.


## Coordinate frames: ECI, ECEF, ENU/NED, sensor/body — and why a target lives in one frame but is seen in another

*A target's state is frame-relative. ECI is inertial (clean physics, orbits/ballistics); ECEF rotates with Earth (constant sensor coords, GPS); ENU/NED are local flat tangent frames where ground tracking actually runs; sensor/body frames are where raw measurements are born. Rotations are orthogonal matrices ($C^{-1}=C^\top$), they compose non-commutatively, and covariance must transform too ($P'=CPC^\top$, or $JPJ^\top$ when nonlinear). Targets are tracked in one frame but measured in another — getting the transform (and its covariance propagation) right is a top source of silent tracking bugs.*

Every filter we have built so far — the scalar Kalman filter, the matrix Kalman filter, the EKF — silently assumed there was *one* place where the state $x$ lived. We wrote $x = [p_x, v_x, p_y, v_y]^\top$ as if "position" and "velocity" were absolute. They are not. A position is only meaningful relative to an origin and a set of axes — a *coordinate frame*. The moment you have a moving sensor, a curved Earth, or two radars on different hills, the comfortable fiction of a single frame collapses, and the deepest source of silent tracking bugs is born: **state and measurement living in different frames, related by a transform you forgot to apply (or applied wrong).** This node builds the frame vocabulary from first principles so the next two nodes (measurement models, registration) have ground to stand on.

**Why frames exist at all.** Newton's laws — the $F$ in our $x_{k+1}=Fx_k$ — hold in an *inertial* frame, one that is not accelerating or rotating. A constant-velocity target really does travel in a straight line at constant speed only when described in an inertial frame. But sensors are bolted to a spinning, orbiting Earth, and operators want answers in 'latitude/longitude/altitude'. So tracking is perpetually a negotiation between *where the physics is clean* (inertial) and *where the measurement is taken* (sensor frame) and *where the answer is wanted* (geographic). Each frame is a tool optimized for one of those jobs.

**The ladder of frames, from most inertial to most local:**

- **ECI (Earth-Centered Inertial):** origin at Earth's center, axes fixed relative to the distant stars (z up the rotation axis, x toward the vernal equinox). The Earth *spins inside it*. This is the frame where $\dot x = $ straight line for an unforced body, so it is the natural frame for ballistic and orbital tracking. Its price: it does not rotate with the Earth, so a ground radar's own position is time-varying in ECI.
- **ECEF (Earth-Centered Earth-Fixed):** same origin (Earth's center) but the axes *rotate with the Earth* — z through the geographic North Pole, x through the intersection of the equator and the prime meridian. A radar bolted to the ground has *constant* coordinates in ECEF, which is why GPS reports position in ECEF (or its geodetic dress, lat/lon/alt on the WGS-84 ellipsoid). The price: ECEF is rotating, hence non-inertial; a straight-line inertial trajectory looks curved (Coriolis) in ECEF.
- **ENU / NED (local tangent plane):** pick a reference point on the Earth (your radar site) at geodetic latitude $\phi$ and longitude $\lambda$; erect a flat Cartesian frame tangent to the ellipsoid there. **ENU** = East, North, Up (right-handed, common in geodesy/robotics). **NED** = North, East, Down (right-handed, beloved in aerospace because 'down' is positive and altitude-loss is intuitive). Over tens of kilometers the Earth's curvature is negligible, so this *flat* frame is where most ground-radar tracking actually runs: the CV/CA motion models behave, and gravity points cleanly along one axis.
- **Sensor / body frame:** attached to the physical sensor. For a radar this is range-azimuth-elevation about the antenna boresight; for an airframe it is roll-pitch-yaw axes through the center of mass. The raw measurement is *born* here.

**Transforms are the glue, and they compose.** A rotation between Cartesian frames is an orthogonal matrix $C$ (so $C^{-1}=C^\top$); a change of origin adds a translation $t$. The canonical example — verified against ESA's Navipedia — is the ECEF→ENU rotation at site latitude $\phi$, longitude $\lambda$:
$$C_{\text{ECEF}\to\text{ENU}} = \begin{bmatrix} -\sin\lambda & \cos\lambda & 0 \\ -\sin\phi\cos\lambda & -\sin\phi\sin\lambda & \cos\phi \\ \cos\phi\cos\lambda & \cos\phi\sin\lambda & \sin\phi \end{bmatrix}.$$
The rows are exactly the East, North, Up unit vectors expressed in ECEF. Because it is orthogonal, the inverse ENU→ECEF transform is just its transpose. To go full circle — geodetic to a track — you chain: lat/lon/alt → ECEF (closed-form with the WGS-84 semi-major axis and flattening) → subtract the site's ECEF position → rotate by $C_{\text{ECEF}\to\text{ENU}}$ → ENU. Transforms compose by matrix multiplication, and **order matters** because rotations do not commute.

**The covariance must travel too — this is the part beginners drop.** A frame transform is not just $x' = Cx + t$ for the *mean*; the uncertainty rotates with it. For a linear transform, $P' = C P C^\top$. Forget this and your beautifully tuned $P$ becomes garbage the instant you cross a frame boundary: an east-west-elongated error ellipse from a distant radar will be reported as if it were north-south. (When the transform is *nonlinear* — geodetic↔Cartesian — you linearize, $P' \approx J P J^\top$ with $J$ the Jacobian, exactly the EKF trick from the previous rung; this is the seam between this node and the next.)

**Worked example — why the frame choice changes the answer.** A radar sits at $\phi=45^\circ$N. A target is 100 km due East and 100 km due North, at the same altitude. In the site's ENU frame its position is simply $(E,N,U)=(100,100,0)$ km — clean, flat, and a CV model tracks it as a straight line. Now express that same target in ECEF: the ENU 'Up' axis is tilted $45^\circ$ from the ECEF z-axis, so the 100 km of 'North' displacement projects partly into ECEF-z and partly into the equatorial plane, and 'East' rotates by the longitude. The numbers become three nonzero ECEF components with no intuitive meaning, and a straight ENU line becomes a slightly curved ECEF arc. Same target, same instant — the *representation*, the *motion model's validity*, and the *covariance shape* all changed. That is the whole lesson: **the target is frame-agnostic; everything you compute about it is frame-specific.**

*(historical and accurate)* The reason ground-radar trackers convert to a flat Cartesian frame at all traces to the SAGE (Semi-Automatic Ground Environment) air-defense system, prototyped at MIT Lincoln Laboratory in the mid-1950s — the experimental Cape Cod / Lexington subsector ran a prototype AN/FSQ-7 (the XD-1) by 1955. Search radars report range and bearing — polar — and SAGE's Direction Centers needed to fuse data from multiple radars onto one common rectangular grid. The conversion was done not at the radar but in the central direction-center computer: a major share of the IBM-built AN/FSQ-7's processing time went to polar-to-rectangular coordinate conversion of incoming radar data (the MIT Lincoln Laboratory Division 6 group co-developed it, with IBM as prime contractor). Frame conversion was a first-class, performance-critical engineering problem from the very dawn of automated tracking. (The Burroughs AN/FST-2 at each radar site digitized the raw range/azimuth/IFF data and transmitted it onward — it was the data link, not the coordinate converter.)

*(practical)* A recurring field failure: a shipborne radar tracks beautifully in its own deck-fixed body frame, then the track is handed to a command system in NED — but nobody compensated for the ship's roll and pitch. On a calm day it works; in a swell the 'Up' axis swings several degrees and every track acquires a wandering bias that looks exactly like a maneuvering target. The fix is not a better filter; it is applying the ship's attitude (from the INS) as a body→NED rotation *before* the filter ever sees the data.


**Q:** What do the acronyms ECI and ECEF stand for, and what is the single key difference between them?

**A:** ECI = Earth-Centered Inertial; ECEF = Earth-Centered Earth-Fixed. Both share Earth's center as origin, but ECI's axes are fixed relative to the stars (the Earth spins inside it, so it is inertial), whereas ECEF's axes rotate with the Earth (so a ground sensor has constant coordinates, but the frame is non-inertial).

**Q:** Spell out the axis ordering and sign convention of ENU versus NED, and name the field that prefers each.

**A:** ENU = East, North, Up (geodesy/robotics favor it). NED = North, East, Down (aerospace favors it because 'down' is positive, matching altitude intuition). Both are right-handed local tangent-plane frames.

**Q:** Why do we usually run a ground-radar tracking filter in a local ENU/NED frame rather than directly in ECEF or geodetic lat/lon/alt?

**A:** ENU/NED is a flat Cartesian frame tangent to the Earth at the site, so over the tens of kilometers of a radar's range the Earth's curvature is negligible: a constant-velocity target really moves in a straight line, gravity points cleanly along one axis, and linear motion models (CV/CA) behave. ECEF makes inertial straight lines curve (it rotates), and geodetic coordinates are nonlinear (degrees of lat/lon are not equal distances), so neither supports a linear motion model directly.

**Q:** When you transform a state estimate from one Cartesian frame to another via a rotation matrix $C$, what must happen to the covariance $P$, and what goes wrong if you skip it?

**A:** The covariance must be rotated too: $P' = C P C^\top$. If you transform only the mean and leave $P$ alone, the error ellipse keeps its old orientation, so an error elongated east-west in the source frame is reported as elongated along the wrong axis in the new frame — corrupting gating, association, and any downstream fusion even though the position looks right.

**Q (cloze):** Complete: A rotation matrix between Cartesian frames is ____, which means its inverse equals its ____; therefore the ENU→ECEF transform is the ____ of the ECEF→ENU transform.

**A:** Complete: A rotation matrix between Cartesian frames is **orthogonal**, which means its inverse equals its **transpose**; therefore the ENU→ECEF transform is the **transpose** of the ECEF→ENU transform.

**Q:** The ECEF→ENU rotation depends on the site's geodetic latitude $\phi$ and longitude $\lambda$. What is the top row of that 3×3 matrix, and what does that row physically represent?

**A:** The top row is $[-\sin\lambda,\ \cos\lambda,\ 0]$. It is the local East unit vector expressed in ECEF coordinates — pointing tangent to the parallel of latitude, so it has no z (polar-axis) component, which is why the third entry is 0.

**Q:** You must track a long-range ballistic / exo-atmospheric object across thousands of kilometers. Which frame is the right home for the *motion model*, and why is a local ENU frame the wrong choice here?

**A:** Use ECI. The object is essentially unforced (or only under gravity), so its trajectory is a clean conic/straight line only in an inertial frame; ECI gives a low-order, well-behaved dynamics model. A local ENU frame is flat and only valid over short ranges — across thousands of km its curvature error is enormous, and being Earth-fixed it is non-inertial, so the trajectory would not be straight even for an unforced body.

**Q:** Derive why feeding a shipborne radar's body-frame tracks into an NED command system, without applying the ship's roll/pitch, produces an apparent 'maneuvering target' on rough seas but works on calm days.

**A:** The measurement is born in the deck-fixed body frame, whose axes swing with the ship's attitude. The correct pipeline is body→NED using the ship's instantaneous roll/pitch (from the INS) before filtering. Omitting that rotation means the body frame is treated as if it equals NED. On calm seas roll/pitch ≈ 0, so the unrotated body frame nearly coincides with NED and the error is tiny. In a swell, roll/pitch oscillate by several degrees, so a stationary target's body-frame position projects a time-varying, oscillating offset into the assumed-NED coordinates — exactly the signature of a wandering/maneuvering target. The fix is the attitude rotation, not a better filter.


## Nonlinear measurement models: range/azimuth/elevation/Doppler ↔ Cartesian, conversion bias, and the debiased/unbiased converted measurement

*Radars measure range/azimuth/elevation/Doppler — nonlinear in Cartesian state. Two doctrines: (1) keep state Cartesian, measurement polar, linearize $h$ via Jacobian (EKF) with naturally-diagonal $R$ in sensor frame; (2) convert the measurement to Cartesian and run a linear KF. Conversion is biased: $E[\cos\tilde\theta]=e^{-\sigma_\theta^2/2}=\lambda_\theta<1$ shrinks the converted coordinate toward the sensor. Lerro & Bar-Shalom (1993) gave the additive debiased converted measurement; Mo et al. (1998) the multiplicative exactly-unbiased version ($\div\lambda_\theta$). Either way you must supply the correct range/bearing-dependent covariance $R_c$ (with a non-zero cross term, since the error ellipse is skewed and far larger cross-range than down-range, with $\cosh/\sinh$ of $2\sigma_\theta^2$). At long range with coarse angles the mis-shaped covariance, not the bias, is the bigger danger. This nonlinearity is precisely what forces EKF/UKF or converted-measurement methods.*

We now have a clean frame to track in (ENU, from the last node) and the EKF/UKF to handle nonlinearity (two rungs back). This node confronts the specific, ubiquitous nonlinearity that *forces* those tools into existence: **a radar does not measure Cartesian position.** It measures range, the angles azimuth and elevation, and often range-rate (Doppler). The target's state lives in Cartesian ENU; the measurement lives in polar/spherical sensor coordinates. The map between them, $h(\cdot)$, is nonlinear, and that single fact reshapes the entire filter.

**Where the measurement is born.** Let the target's ENU position relative to the radar be $(x,y,z)$ with $x=$ East, $y=$ North, $z=$ Up. The noiseless measurements are
$$ r=\sqrt{x^2+y^2+z^2},\quad \theta=\operatorname{atan2}(x,\,y)\ \text{(azimuth, clockwise from North)},\quad \varepsilon=\arcsin\!\big(z/r\big)\ \text{(elevation)},\quad \dot r = \frac{x\dot x + y\dot y + z\dot z}{r}\ \text{(range-rate)}.$$
The range-rate / Doppler term is the projection of the velocity vector onto the line of sight — it injects velocity information directly into the measurement, which is enormously valuable, but it is also the most violently nonlinear component because it couples position and velocity through a quotient. The measurement-noise covariance $R$ is naturally diagonal *in this sensor frame*: $\sigma_r$ (meters), $\sigma_\theta,\sigma_\varepsilon$ (radians), $\sigma_{\dot r}$ (m/s) are physically independent error sources. That diagonal-in-polar structure is the crux of everything that follows.

**Two doctrines for handling the nonlinearity.** (1) **Mixed-coordinate / EKF-in-measurement-space:** keep the state in Cartesian, leave the measurement in polar, and write the nonlinear $h$ with its Jacobian $H=\partial h/\partial x$. The innovation $\nu = z - h(\hat x)$ and innovation covariance $S = HPH^\top + R$ are formed with $R$ in its natural diagonal polar form — clean noise model, but the linearization of $h$ injects error. (2) **Converted-measurement / linear-KF:** convert the polar measurement to a Cartesian pseudo-measurement up front, $z_c = (r\cos\varepsilon\sin\theta,\, r\cos\varepsilon\cos\theta,\, r\sin\varepsilon)$ (East, North, Up), then run an ordinary *linear* Kalman filter with $H=[\,I\ 0\,]$. This is tempting — the filter becomes linear again — but the conversion is where a subtle, classic trap lives.

**The conversion bias (the heart of this node).** Convert a noisy polar measurement to Cartesian and the result is *biased* — its mean is not the true position. Take a 2-D bearing-only intuition: the converted x-coordinate is $x_c = r_m\cos\theta_m$, where $\theta_m=\theta+\tilde\theta$ carries zero-mean noise $\tilde\theta\sim\mathcal N(0,\sigma_\theta^2)$. Then $E[\cos\theta_m]=\cos\theta\,E[\cos\tilde\theta]=\cos\theta\,e^{-\sigma_\theta^2/2}$, using the Gaussian characteristic-function identity $E[\cos\tilde\theta]=\operatorname{Re}\,E[e^{i\tilde\theta}]=e^{-\sigma_\theta^2/2}$. So the *average* converted x is shrunk by the factor $\lambda_\theta=e^{-\sigma_\theta^2/2}<1$ relative to the truth. The conversion systematically pulls measurements *toward the sensor* along the arc — the noisier the angle, the worse. This is multiplicative and depends on the statistics of the cosine of the angle error.

**Removing the bias — two equivalent doctrines, two papers.** Lerro & Bar-Shalom (1993) introduced the *additive* debiased converted measurement: subtract the (estimated) average bias before filtering, e.g. for the 2-D case $E[\tilde x\mid r_m,\theta_m]=r_m\cos\theta_m\,(e^{-\sigma_\theta^2}-e^{-\sigma_\theta^2/2})$. Mo, Song, Zhou, Sun & Bar-Shalom (1998) later gave the *multiplicative* unbiased converted measurement, which is exactly unbiased and cleaner to apply — simply scale by the reciprocal bias factor:
$$ x_u = \frac{r_m\cos\theta_m}{\lambda_\theta},\qquad y_u = \frac{r_m\sin\theta_m}{\lambda_\theta},\qquad \lambda_\theta=e^{-\sigma_\theta^2/2}\ \ (\text{equivalently } x_u=e^{+\sigma_\theta^2/2}r_m\cos\theta_m). $$
But correcting the *mean* is only half the job — the converted-measurement **covariance** $R_c$ must also be computed correctly, and it is range- and bearing-dependent (no longer diagonal!). The standard 2-D converted covariance elements (Lerro & Bar-Shalom) are
$$ R_{11}=r_m^2 e^{-2\sigma_\theta^2}\!\big[\cos^2\theta_m(\cosh 2\sigma_\theta^2-\cosh\sigma_\theta^2)+\sin^2\theta_m(\sinh 2\sigma_\theta^2-\sinh\sigma_\theta^2)\big]+\sigma_r^2 e^{-2\sigma_\theta^2}\!\big[\cos^2\theta_m\cosh 2\sigma_\theta^2+\sin^2\theta_m\sinh 2\sigma_\theta^2\big], $$
$$ R_{22}=r_m^2 e^{-2\sigma_\theta^2}\!\big[\sin^2\theta_m(\cosh 2\sigma_\theta^2-\cosh\sigma_\theta^2)+\cos^2\theta_m(\sinh 2\sigma_\theta^2-\sinh\sigma_\theta^2)\big]+\sigma_r^2 e^{-2\sigma_\theta^2}\!\big[\sin^2\theta_m\cosh 2\sigma_\theta^2+\cos^2\theta_m\sinh 2\sigma_\theta^2\big], $$
$$ R_{12}=\sin\theta_m\cos\theta_m\, e^{-4\sigma_\theta^2}\big[\sigma_r^2+(r_m^2+\sigma_r^2)(1-e^{\sigma_\theta^2})\big]. $$
The non-zero cross term $R_{12}$ is the geometric truth that converted error is an ellipse skewed by the line-of-sight angle — far longer in the cross-range (angular) direction than down-range (radial) at long range. Feed *that* $R_c$ into a linear KF and you get a consistent, near-optimal filter without any Jacobian.

**Worked numerical example.** A 2-D radar reports $r_m=50\text{ km}$, $\theta_m=30^\circ$, with $\sigma_r=50\text{ m}$ and $\sigma_\theta=15\text{ mrad}$ ($\approx 0.86^\circ$). The naive conversion gives $x=r\cos\theta=43.301$ km. The bias factor is $\lambda_\theta=e^{-(0.015)^2/2}=e^{-1.125\times10^{-4}}=0.9998875$, so the unbiased $x_u=43.301/0.9998875\approx43.306$ km — a $+4.9$ m correction. Tiny? Yes, at $\sigma_\theta=15$ mrad. Now make it a cheap sensor with $\sigma_\theta=3^\circ\approx52.4$ mrad: $\lambda_\theta=e^{-0.00137}=0.99863$, and the correction grows to $\sim 59$ m — and the *cross-range* standard deviation is $r\sigma_\theta\approx 50000\times0.0524\approx 2.6$ km, dwarfing the $50$ m down-range $\sigma_r$ by a factor of about 50. This is the lesson in one number: **at long range with a coarse angle sensor, your error ellipse is wildly anisotropic, and pretending $R$ is diagonal-isotropic-Cartesian (e.g. just sticking $\sigma_r$ on both axes) is catastrophically wrong.** The bias is often the *smaller* sin; the mis-shaped covariance is the larger one.

**Why this forces EKF/UKF or converted-measurement methods.** A plain linear KF needs a linear $h$ and a correct Cartesian $R$. Polar measurements give neither. So you must either (a) linearize $h$ → EKF, which the conversion bias actually warns us about: the EKF's first-order Jacobian *ignores* exactly the second-order bias term encoded in $\lambda_\theta$, so a raw EKF in measurement space is itself slightly biased and can be optimistic; (b) use sigma points → UKF, which captures the nonlinearity-induced mean shift and covariance to higher order — often the cleanest route for strong Doppler nonlinearity; or (c) do the debiased/unbiased conversion above and run a linear KF on the corrected pseudo-measurement with the consistent $R_c$.

*(historical and accurate)* The debiased converted-measurement Kalman filter was introduced by D. Lerro and Y. Bar-Shalom, "Tracking with Debiased Consistent Converted Measurements Versus EKF," *IEEE Transactions on Aerospace and Electronic Systems*, Vol. 29, No. 3, July 1993, pp. 1015–1022. They analytically derived the conversion bias and a consistent converted covariance, and showed the debiased converted filter could outperform the mixed-coordinate EKF over practical geometries — a key demonstration that 'just linearize it' is not always the right reflex. Five years later, L. Mo, X. Song, Y. Zhou, Z. K. Sun and Y. Bar-Shalom, "Unbiased Converted Measurements for Tracking," *IEEE TAES*, Vol. 34, No. 3, 1998, pp. 1023–1027, recast the correction in its now-standard *multiplicative* (exactly-unbiased) form, multiplying the raw converted measurement by the reciprocal bias factor $e^{+\sigma_\theta^2/2}$.

*(practical)* A frequent production bug: an engineer converts polar to Cartesian, correctly debiases the mean, then sets $R_c=\operatorname{diag}(\sigma_r^2,\sigma_r^2)$ because 'range is the dominant error'. The filter passes calm tests, then diverges on long-range crossing targets — because the true cross-range error ($r\sigma_\theta$) is orders of magnitude larger than $\sigma_r$, and the omitted $R_{12}$ cross term means gates point the wrong way. The mean was right; the *shape* was the bug.


**Q:** List the four quantities a typical tracking radar measures, and state which Cartesian quantity range-rate (Doppler) carries information about.

**A:** Range $r$, azimuth $\theta$, elevation $\varepsilon$, and range-rate $\dot r$ (Doppler). Range-rate is the projection of the velocity vector onto the line of sight, so it carries velocity information directly into the measurement.

**Q:** In which coordinate frame is a radar's measurement-noise covariance $R$ naturally diagonal, and why is that physically true?

**A:** In the sensor (polar/spherical) frame. The range error, angle errors, and Doppler error arise from physically independent mechanisms (range from timing, angles from beam/monopulse, Doppler from frequency), so $R=\operatorname{diag}(\sigma_r^2,\sigma_\theta^2,\sigma_\varepsilon^2,\sigma_{\dot r}^2)$ in sensor coordinates. It is generally NOT diagonal after conversion to Cartesian.

**Q:** When you convert a noisy polar measurement to Cartesian, why is the result biased, and in which direction does the bias point?

**A:** Because the conversion is nonlinear in the angle: $E[\cos\tilde\theta]=e^{-\sigma_\theta^2/2}<1$ for zero-mean Gaussian angle noise $\tilde\theta$, so the averaged converted coordinate is shrunk by that factor. The bias pulls the converted position systematically toward the sensor (shortens the apparent range along the arc); it grows with angle-noise variance $\sigma_\theta^2$.

**Q:** Complete the multiplicative unbiasing: for 2-D conversion the bias factor is $\lambda_\theta = E[\cos\tilde\theta] = $ $e^{-\sigma_\theta^2/2}$, and the unbiased coordinate is $x_u = r_m\cos\theta_m$ divided by $\lambda_\theta$ (equivalently multiplied by $e^{+\sigma_\theta^2/2}$).

**A:** $e^{-\sigma_\theta^2/2}$; divided by $\lambda_\theta$

**Q:** After correcting the converted-measurement mean, why must the converted covariance $R_c$ have a non-zero off-diagonal (cross) term, and what does that term encode geometrically?

**A:** Because the conversion mixes range and angle errors through the line-of-sight rotation, so the Cartesian error ellipse is tilted along the bearing direction rather than aligned with the x/y axes. The off-diagonal $R_{12}$ encodes that tilt: the error is long in the cross-range (angular) direction and short in the down-range (radial) direction, and the principal axes are rotated by the bearing $\theta$. A diagonal $R_c$ would falsely claim x and y errors are independent and axis-aligned.

**Q:** A radar at $r=50$ km has angle accuracy $\sigma_\theta=3^\circ$ ($\approx52$ mrad) and range accuracy $\sigma_r=50$ m. Compare the cross-range and down-range position errors. What does this imply about modeling $R_c$ as $\operatorname{diag}(\sigma_r^2,\sigma_r^2)$?

**A:** Cross-range $\sigma \approx r\sigma_\theta = 50000 \times 0.0524 \approx 2.6$ km; down-range $\sigma \approx \sigma_r = 50$ m. The cross-range error is about 50× larger. Modeling $R_c=\operatorname{diag}(\sigma_r^2,\sigma_r^2)$ is catastrophically wrong: it both ignores the dominant cross-range uncertainty and mis-orients the ellipse, so the filter will be wildly overconfident in the cross-range direction and gating/association will point the wrong way.

**Q:** Why does a standard EKF that linearizes the polar measurement function $h$ remain slightly biased on this conversion, and how does the unbiased converted-measurement KF avoid that specific error?

**A:** The EKF uses only the first-order Jacobian of $h$, which is linear and therefore captures no second-order (curvature) effects. But the conversion bias factor $\lambda_\theta=e^{-\sigma_\theta^2/2}$ is precisely a second-order effect of the angle variance — invisible to a first-order linearization. So the EKF inherits a small, unmodeled bias and can be optimistic. The (un)debiased converted-measurement KF computes the exact mean correction (multiply by $1/\lambda_\theta$) and the consistent (non-diagonal, range/bearing-dependent) covariance analytically, so it removes the bias the EKF's linearization silently drops.

**Q:** State the citation (authors, journal, year) of the paper that introduced the debiased consistent converted-measurement filter, and the one-sentence claim it established versus the EKF.

**A:** D. Lerro and Y. Bar-Shalom, 'Tracking with Debiased Consistent Converted Measurements Versus EKF,' IEEE Transactions on Aerospace and Electronic Systems, Vol. 29, No. 3, 1993, pp. 1015–1022. It established that converting polar measurements to Cartesian introduces a bias dependent on the angle-error statistics, and that a properly debiased, consistently-covariance'd converted-measurement Kalman filter can outperform the mixed-coordinate EKF across practical geometries. (The exactly-unbiased multiplicative form was given later by Mo, Song, Zhou, Sun & Bar-Shalom, IEEE TAES vol. 34, no. 3, 1998.)

**Q:** For a sensor whose dominant nonlinearity is range-rate (Doppler), why might a UKF be preferred over both the EKF and the position-only converted-measurement approach?

**A:** Range-rate $\dot r=(x\dot x+y\dot y+z\dot z)/r$ couples position and velocity through a quotient — strongly nonlinear, and not addressable by the position-only polar-to-Cartesian debiasing (which handles range/angle, not Doppler). The EKF's first-order Jacobian poorly captures this curvature. The UKF propagates sigma points through the exact nonlinear $h$, capturing the induced mean shift and covariance to higher order without Jacobians, so it handles the position–velocity Doppler coupling far more faithfully than EKF linearization, while the basic converted-measurement trick simply does not cover the velocity-coupled measurement.


## Time and registration: timestamping, sensor bias estimation, and out-of-sequence measurements

*Three time/truth problems beyond the textbook filter. (1) Timestamp at time-of-validity, not time-of-receipt — latency injects a correlated, velocity-bias-shaped error into $F/Q$. (2) Registration: biases are systematic (boresight, range offset, survey, clock) and do NOT average out; with multiple sensors they create ghost tracks. Range bias decouples per-sensor; azimuth/orientation bias is not separately observable from one sensor (it trades off against velocity) and needs common targets or GPS truth. Treat a bias as a hidden near-constant state and estimate it off-line (LS/ML) or on-line (augmented/two-stage Friedland filter). (3) Out-of-sequence measurements break the in-order assumption; discard (lossy), reprocess (exact, costly), or retrodict (predict the state backward to the OOSM time, fold the innovation into the current estimate via cross-covariance) — Bar-Shalom 2002/2004. All three are impossible without a time-of-validity timestamp on every measurement.*

The previous two nodes fixed *where* a measurement lives (frames) and *what shape* its error is (nonlinear models, debiasing). This node fixes the last two coordinates of a measurement that beginners assume are free: **when it happened, and whether the sensor that produced it is telling the truth about its own geometry.** Get either wrong and no amount of clever filtering saves you — these are the errors that masquerade as targets, split one track into two, or quietly inflate your covariance until the filter stops believing anything.

**1. Timestamping — the measurement's most important coordinate.** The Kalman predict step uses the elapsed time $\Delta t$ to propagate $x$ via $F(\Delta t)$ and grow uncertainty via $Q(\Delta t)$. If you stamp a measurement with the time it *arrived at the CPU* instead of the time the *energy left the target*, you have lied to $F$. Consider a target at 300 m/s with a 50 ms latency between detection and processing: that is 15 m of position error injected on *every single scan*, perfectly correlated frame-to-frame — exactly the signature of a velocity bias the filter will dutifully (and wrongly) 'learn'. The discipline is: timestamp at the **time of validity** (when the phenomenon occurred), not the time of receipt, and carry that timestamp with the measurement through the whole pipeline. A networked tracker must also reconcile clocks across sensors; an unsynchronized 20 ms offset between two radars is, geometrically, a registration bias.

**2. Registration / sensor bias — the systematic lie.** Measurement noise $R$ models *random*, zero-mean error. **Bias** is the opposite: a *systematic*, repeatable offset — a radar boresight (azimuth pointing) misaligned by $0.5^\circ$, a range offset from an uncalibrated cable delay or atmospheric refraction, a survey error in the sensor's own reported position, a timing offset. These do not average out; they persist. With one sensor a constant bias is often invisible (the track is self-consistent, just shifted). With **two or more** sensors the biases collide: the same target appears at two slightly different places, and a fusion system either (a) forms a single track with inflated covariance, or (b) worst case, declares *two* targets — a **ghost track**. Registration is the process of *estimating and removing* these systematic biases before (or jointly with) tracking. The classic separation result: each sensor's **range bias decouples** and can be estimated from its own local measurements, while the **azimuth (orientation) bias** is *not* separately observable from a single sensor — it is coupled (in the single-sensor case it trades off against the target's own velocity/heading) and needs common targets seen by two sensors (or a GPS-instrumented 'truth' target) to observe. Methods split into **off-line** (least-squares, maximum-likelihood batch estimation over a window of common detections) and **on-line** (augment the state vector with the bias parameters and let an augmented Kalman filter — often a two-stage Friedland-style estimator that separates bias from kinematic state — estimate them on the fly). The key insight: **a bias is just a slowly-varying (often constant) hidden state**, so the same estimation machinery applies — you simply add $b$ to the state and give it near-zero process noise.

**Worked registration example.** Two radars, A and B, both watch a transponder-equipped aircraft whose true ENU position is known from its GPS to be at azimuth $90.0^\circ$ from A. Over 200 scans, radar A consistently reports $90.4^\circ \pm 0.05^\circ$. The $0.4^\circ$ offset is about 8× larger than the $0.05^\circ$ random spread and does not shrink with averaging — it is a bias, not noise. At 100 km range, $0.4^\circ = 0.00698$ rad gives a cross-range position error of $100\,\text{km} \times 0.00698 \approx 698$ m, fixed in direction. If radar B has its own $-0.3^\circ$ bias, the two radars place the *same* aircraft about $0.7^\circ$ apart in azimuth — over a kilometer at 100 km — and a naive fusion gates them as two separate targets. Estimating $\hat b_A=+0.4^\circ$, $\hat b_B=-0.3^\circ$ from the common GPS truth and subtracting them collapses the ghost into one track. Note that what saved us was an *independent* reference (GPS); biases are only observable relative to something you trust.

**3. Out-of-sequence measurements (OOSM) — when 'when' breaks the recursion.** The Kalman filter is built on a strict assumption: measurements arrive in time order. Real multisensor networks violate this constantly — a measurement taken at time $\tau$ may arrive *after* the filter has already processed measurements up to a later time $t_k$ ($\tau < t_k$), because of variable communication delay or sensor processing latency. You cannot simply run the predict-update step: that would *predict backward in time*, and the standard predict step only propagates forward (it grows covariance by adding $Q$, an operation that has no valid 'run-in-reverse' as an ordinary update). Three doctrines: **(i) discard** the OOSM — simple, but throws away information (bad for sparse/precious detections); **(ii) reprocess** — buffer all raw measurements and re-run the filter from $\tau$ forward — exact, but unbounded memory and compute; **(iii) retrodiction** — the elegant compromise: *retrodict* (predict the current estimate backward) the state and covariance from $t_k$ to the OOSM time $\tau$, compute the innovation between the delayed measurement and that retrodicted state, and fold it into the *current* estimate at $t_k$ using the cross-covariance between the states at $\tau$ and $t_k$. The retrodicted state is $\hat x(\tau|t_k)$ with covariance $P(\tau|t_k)$, the innovation is $\nu = z(\tau) - H\hat x(\tau|t_k)$ with $S = HP(\tau|t_k)H^\top + R$, and the current state is corrected by a gain that accounts for the time gap. Retrodiction gives a near-optimal update at bounded cost — it is the standard tool. *(historical and accurate)* The exact one-lag solution was given by Y. Bar-Shalom, 'Update with Out-of-Sequence Measurements in Tracking: Exact Solution,' *IEEE Transactions on Aerospace and Electronic Systems*, vol. 38, no. 3, 2002, pp. 769–777; the multistep (multiple-lag) generalization is Y. Bar-Shalom, H. Chen & M. Mallick, 'One-Step Solution for the Multistep Out-of-Sequence-Measurement Problem in Tracking,' *IEEE TAES*, vol. 40, no. 1, 2004, pp. 27–37.

*(metaphorical)* An OOSM is a postcard that arrives a week late. You have already lived several more days, so you cannot pretend you just received it on the day it was written. But you *can* mentally rewind to that day (retrodiction), read what the postcard tells you about that moment, and let it gently revise your memory of the whole week — without un-living the days in between. Discarding is throwing the postcard away; reprocessing is re-living the entire week.

*(practical)* The most common OOSM bug is not a wrong formula but a *missing timestamp*: a sensor reports detections without a time-of-validity field, the fusion node stamps them on arrival, and out-of-order arrivals are silently treated as in-order. The filter does not crash — it just slowly drifts and over-smooths, and the symptom (lagging tracks on fast targets) gets misdiagnosed as a too-large $Q$. Always plumb the time-of-validity through; OOSM handling is impossible without it.


**Q:** What time should a measurement be stamped with — time of receipt at the processor, or time of validity — and which Kalman quantity uses that time?

**A:** Time of validity (when the phenomenon actually occurred / energy left the target), not time of receipt. That timestamp sets $\Delta t$ used by the predict step's transition $F(\Delta t)$ and process-noise $Q(\Delta t)$.

**Q:** What is the difference between measurement noise (modeled by $R$) and sensor bias?

**A:** Measurement noise is random and zero-mean — it averages out over many measurements and is captured by $R$. Sensor bias is a systematic, repeatable offset (e.g. boresight misalignment, range offset, clock skew) that does NOT average out; $R$ does not model it, and it must be estimated and removed by registration.

**Q:** Why is a constant sensor bias often invisible with a single sensor but dangerous with two or more, and what is the worst-case failure?

**A:** With one sensor a constant bias merely shifts the whole track consistently — it stays self-consistent and self-gating, so it hides. With two sensors the biases differ, so the same target appears at two slightly different places; fusion either inflates the covariance or, worst case, declares two separate targets (a ghost track).

**Q:** How can a sensor bias be estimated using the same machinery as the Kalman filter? What process noise do you assign it?

**A:** Treat the bias as an extra hidden state: augment the state vector with the bias parameters $b$. Since a bias is constant (or only slowly varying), give it near-zero process noise so the filter integrates it like a constant. The augmented (or two-stage Friedland-style) filter then estimates $b$ jointly with the kinematic state. This is the on-line registration approach.

**Q (cloze):** Complete the registration separation result and observability point: each sensor's ____ bias decouples and can be estimated from its own local measurements, but the ____ bias is not separately observable from a single sensor and is only resolvable relative to a trusted reference such as a common target seen by two sensors or ____ truth.

**A:** Complete the registration separation result and observability point: each sensor's **range** bias decouples and can be estimated from its own local measurements, but the **azimuth/orientation** bias is not separately observable from a single sensor and is only resolvable relative to a trusted reference such as a common target seen by two sensors or **GPS** truth.

**Q:** A radar consistently reports a target at $90.4^\circ$ azimuth when GPS truth says $90.0^\circ$, with $\pm 0.05^\circ$ scatter, at 100 km range. Argue it is a bias not noise, and quantify the resulting position error.

**A:** The $0.4^\circ$ offset is ~8× larger than the $0.05^\circ$ random scatter and is repeatable (does not shrink with averaging), so it is a systematic bias, not zero-mean noise. Converting: $0.4^\circ = 0.00698$ rad, so cross-range error $\approx 100{,}000\,\text{m} \times 0.00698 \approx 698$ m, fixed in direction. Estimating $\hat b = +0.4^\circ$ from the GPS reference and subtracting it removes the offset.

**Q:** What is an out-of-sequence measurement (OOSM), and why can't you just run a normal predict-update step to incorporate it?

**A:** An OOSM is a measurement taken at time $\tau$ that arrives after the filter has already processed measurements up to a later time $t_k$ ($\tau < t_k$), due to communication/processing latency. You can't run a normal predict-update because that assumes measurements arrive in time order; incorporating it directly would require predicting the state backward in time to $\tau$, and the standard predict step only propagates forward (it grows covariance by adding $Q$, which has no valid run-in-reverse as an ordinary update).

**Q:** Compare the three OOSM strategies — discard, reprocess, retrodict — on information loss, memory/compute cost, and optimality, and say which is the standard choice and how it works.

**A:** Discard: zero extra cost but throws away the OOSM's information (bad when detections are sparse/precious). Reprocess: buffer all raw measurements and re-run the filter from $\tau$ forward — exact/optimal but requires unbounded memory and compute. Retrodict (the standard choice): predict the current estimate backward to the OOSM time $\tau$ to get $\hat x(\tau|t_k)$ and $P(\tau|t_k)$, form the innovation $\nu=z(\tau)-H\hat x(\tau|t_k)$ with $S=HP(\tau|t_k)H^\top+R$, and fold it into the current estimate at $t_k$ using the cross-covariance between the states at $\tau$ and $t_k$. It is near-optimal at bounded cost — the best compromise.

**Q:** Cite the paper that gave the exact one-lag OOSM solution and explain why a missing time-of-validity timestamp makes OOSM handling impossible and is commonly misdiagnosed.

**A:** Y. Bar-Shalom, 'Update with Out-of-Sequence Measurements in Tracking: Exact Solution,' IEEE Transactions on Aerospace and Electronic Systems, vol. 38, no. 3, 2002, pp. 769–777 (the multistep generalization is Bar-Shalom, Chen & Mallick, IEEE TAES vol. 40, no. 1, 2004, pp. 27–37). Without a time-of-validity timestamp, the fusion node stamps measurements on arrival, so out-of-order arrivals are silently treated as in-order — you cannot retrodict to the true $\tau$ because you don't know it. The filter doesn't crash; it drifts and over-smooths, and the lagging-track symptom is commonly misdiagnosed as a too-large $Q$ rather than an OOSM/timestamp problem.


## Sensor fusion: centralized measurement fusion vs distributed track-to-track fusion (and the correlation problem)

*Two fusion architectures — centralized (feed all raw measurements to one Kalman filter) and distributed (each sensor builds a track, then fuse the tracks) — and why naively averaging two tracks is wrong: common process noise makes their errors correlated. Remedies: the Bar-Shalom–Campo cross-covariance formula when the correlation is known, and covariance intersection when it is not.*

We now have everything we need to run a single Kalman filter beautifully. But a real surveillance system has *many* sensors — a radar, an IR camera, an ESM receiver, perhaps a second radar on another platform — all looking at the same sky. The question of this node is deceptively simple: **how do you combine information from several sensors into one better estimate?** The answer splits into two architectures, and the choice between them turns on a subtlety that wrecks the naive approach: *the errors in two independently-built tracks of the same target are correlated, even when the sensors never talk to each other.*

## Two architectures

**Centralized (measurement-level) fusion.** Every sensor ships its raw detections — each $z$ with its own measurement matrix $H_i$ and noise $R_i$, expressed in a common frame (this is exactly why n5-frames mattered: you must rotate everything into, say, a shared ENU frame before fusing) — to a single fusion center. That center runs *one* Kalman filter on the combined measurement stream. Mathematically this is trivial: at each scan you simply stack the measurements, $z=[z_1;z_2]$, $H=[H_1;H_2]$, $R=\mathrm{blkdiag}(R_1,R_2)$, and run the ordinary multivariate update with innovation $\nu=z-H\hat{x}$, innovation covariance $S=HPH^\top+R$, and gain $K=PH^\top S^{-1}$. Because every measurement enters the one filter exactly once, *there is no double counting and no correlation problem*. Centralized fusion is the gold standard for accuracy — it is provably optimal (it is just *the* Kalman filter on all the data). Its costs are practical: you must transmit every detection over the network (high bandwidth), you need tight time alignment, and a single fusion node is a bottleneck and a single point of failure.

**Distributed (track-to-track) fusion.** Each sensor runs its *own* local tracker and produces a full track: a state estimate $\hat{x}_i$ with covariance $P_{ii}$. Only these tracks — not the raw measurements — are sent to the fusion center, which combines $\hat{x}_1,\hat{x}_2$ into a global track. This slashes communication (a track is sent once per second, not every detection), spreads the compute across the sensors, and degrades gracefully if a node dies. Modern multi-platform and automotive systems lean on it heavily. *(practical)* It is also more robust to residual sensor bias, since each local tracker can be tuned to its own sensor. The price is the topic of this node: combining two tracks correctly is **not** a simple Kalman update.

## Why naive fusion fails: common process noise

Suppose sensor 1 reports $\hat{x}_1,P_{11}$ and sensor 2 reports $\hat{x}_2,P_{22}$. The tempting move is to treat them as two independent measurements of the truth and fuse them with the information-form Kalman combination,
$$P_f^{-1}=P_{11}^{-1}+P_{22}^{-1},\qquad P_f^{-1}\hat{x}_f=P_{11}^{-1}\hat{x}_1+P_{22}^{-1}\hat{x}_2.$$
This is correct **only if the two estimation errors are independent.** They are not. Both local filters propagate the same target through the *same motion model* $F$ with the *same process noise* $Q$ — the target's actual unmodeled accelerations (a gust of wind, a real maneuver) are a single physical reality that perturbs *both* tracks identically. So the errors $\tilde{x}_1=x-\hat{x}_1$ and $\tilde{x}_2=x-\hat{x}_2$ share a common component: the cross-covariance $P_{12}=E[\tilde{x}_1\tilde{x}_2^\top]$ is **nonzero**. The naive formula, by assuming $P_{12}=0$, double-counts the shared information and produces a $P_f$ that is *too small* — an overconfident, inconsistent estimate. Run it in a feedback loop and the filter can diverge. This is a flavor of the **data-incest** problem: information that is really one piece gets counted twice. *(historical and accurate)* It was precisely this nonzero cross-covariance from common process noise that Yaakov Bar-Shalom and Leon Campo analyzed in their 1986 note "The Effect of the Common Process Noise on the Two-Sensor Fused-Track Covariance," *IEEE Transactions on Aerospace and Electronic Systems*, vol. AES-22, no. 6, pp. 803–805 (Nov. 1986). For an $\alpha$–$\beta$ tracker they showed the honest fused uncertainty area is about **70%** of a single sensor's, not the **50%** the independence assumption would predict — a quantitative measure of how badly the naive formula lies.

## The cross-covariance recursion

The fix, when you *can* compute it, is to track $P_{12}$ explicitly. For two synchronous sensors with the same $F,Q$ and gains $K_1,K_2$, the cross-covariance obeys its own Lyapunov-like recursion (cf. Bar-Shalom & Fortmann, *Tracking and Data Association*, §8.4):
$$P_{12}(k)=(I-K_1H_1)\big[F\,P_{12}(k-1)\,F^\top+Q\big](I-K_2H_2)^\top.$$
Notice the $+Q$ inside the brackets: even if $P_{12}$ starts at zero, the shared $Q$ injects correlation at every step, and it persists because $(I-K_iH_i)$ never fully zeroes it out. *(metaphorical)* Two boats anchored in the same harbor: each crew tries to estimate their position, but the same swell lifts both — their errors bob together no matter how good each crew is.

## The Bar-Shalom–Campo formula

Given $P_{12}$, the minimum-mean-square linear fusion is
$$\hat{x}_f=\hat{x}_1+(P_{11}-P_{12})(P_{11}+P_{22}-P_{12}-P_{21})^{-1}(\hat{x}_2-\hat{x}_1),$$
$$P_f=P_{11}-(P_{11}-P_{12})(P_{11}+P_{22}-P_{12}-P_{21})^{-1}(P_{11}-P_{21}),$$
where $P_{21}=P_{12}^\top$. When $P_{12}=0$ this collapses back to the naive information-form combination (Millman's formula); the cross-terms are exactly the correction for shared noise. (Millman's formula is the uncorrelated-error special case; Bar-Shalom–Campo is its correlated generalization.)

## Worked example (scalar, to expose the bug)

Let both sensors report the same scalar position $\hat{x}_1=\hat{x}_2=10$, each with variance $P_{11}=P_{22}=4$. Suppose the true cross-covariance is $P_{12}=3$ (correlation $\rho=P_{12}/\sqrt{P_{11}P_{22}}=3/4$ — highly correlated, common-$Q$ dominates). **Naive fusion:** $P_f^{-1}=1/4+1/4=0.5\Rightarrow P_f=2$. It claims variance 2, a halving. **Bar-Shalom–Campo:** the gain factor is $(P_{11}-P_{12})/(P_{11}+P_{22}-2P_{12})=(4-3)/(4+4-6)=1/2$, and $P_f=4-(4-3)\cdot\tfrac{1}{2}\cdot(4-3)=4-0.5=3.5$. The honest fused variance is **3.5**, only a 12.5% reduction. The naive answer of 2 is *wildly overconfident* — it asserts the two tracks carry nearly independent information when in fact they almost entirely overlap. As $P_{12}\to P_{11}$ (perfectly correlated, identical tracks), BC correctly gives $P_f\to P_{11}$ (fusing a track with itself buys nothing), while the naive formula stays pinned at $P_{11}/2$ no matter how correlated the inputs are. That gap is the entire reason this node exists.

## When you can't compute $P_{12}$: covariance intersection

BC requires you to *know* the cross-covariance. In real distributed networks you often cannot: tracks have circulated through a graph, been re-fused, and relabeled, so the true correlation is unknown (the data-incest / common-history problem). Simon Julier and Jeffrey Uhlmann's answer, **Covariance Intersection (CI)**, *(historical and accurate)* introduced in "A Non-divergent Estimation Algorithm in the Presence of Unknown Correlations," *Proc. 1997 American Control Conference*, Albuquerque, NM, vol. 4, pp. 2369–2373, gives a fused estimate that is **guaranteed consistent for any possible correlation**:
$$P_{CI}^{-1}=\omega P_{11}^{-1}+(1-\omega)P_{22}^{-1},\qquad P_{CI}^{-1}\hat{x}_{CI}=\omega P_{11}^{-1}\hat{x}_1+(1-\omega)P_{22}^{-1}\hat{x}_2,$$
with $\omega\in[0,1]$ chosen to minimize $\mathrm{tr}(P_{CI})$ or $\det(P_{CI})$. Geometrically, the CI covariance ellipse always encloses the intersection of the two input ellipses — hence the name — so it never claims more certainty than the data can justify. It is conservative (never overconfident) but at the cost of being looser than BC when the correlation actually *is* known. *(practical)* CI became a workhorse of decentralized SLAM and multi-robot localization, exactly because robots fuse maps of unknown common provenance. The decision tree is therefore: **centralized** if you can afford the bandwidth and want optimality; **track-to-track with BC** if distributed and you can maintain $P_{12}$; **track-to-track with CI** if distributed and the correlation is unknown.


**Q:** In CENTRALIZED (measurement-level) fusion, what data do the sensors send to the fusion center, and what runs there?

**A:** Each sensor sends its raw measurements (with its own H_i and R_i, in a common frame); the fusion center runs a single Kalman filter on the combined measurement stream.

**Q:** In DISTRIBUTED (track-to-track) fusion, what does each sensor send to the fusion center?

**A:** A full local track: its state estimate x̂_i together with its covariance P_ii (not the raw measurements).

**Q:** Why are the estimation errors of two independently-built tracks of the SAME target correlated, even though the sensors never communicate?

**A:** Both local filters propagate the same target through the same motion model F and the same process noise Q; the target's actual unmodeled accelerations perturb both tracks identically, creating a nonzero cross-covariance P12 — the 'common process noise' coupling.

**Q:** Applied to two correlated tracks, the naive information-form fusion P_f^{-1} = P11^{-1} + P22^{-1} produces a fused covariance with what specific defect?

**A:** A fused covariance that is too small (overconfident / inconsistent): by assuming P12 = 0 it double-counts the shared information.

**Q:** Why is an overconfident (too-small) fused covariance dangerous when the fused track is fed back into the local filters?

**A:** In a feedback loop the underestimated covariance is re-used as if it were certain information, repeatedly counting the same data (data incest), which can drive the filter to diverge.

**Q:** For two synchronous sensors sharing F and Q, the track cross-covariance obeys P12(k) = (I − K1 H1)[ F P12(k−1) Fᵀ + ___ ](I − K2 H2)ᵀ. The blank term is what keeps injecting correlation each step even if P12 started at zero.

**A:** Q

**Q:** State the Bar-Shalom–Campo fused ESTIMATE formula for combining x̂1, x̂2 with covariances P11, P22 and cross-covariance P12 (P21 = P12ᵀ).

**A:** x̂_f = x̂1 + (P11 − P12)(P11 + P22 − P12 − P21)^{-1}(x̂2 − x̂1).

**Q:** State the Bar-Shalom–Campo fused COVARIANCE formula (P21 = P12ᵀ).

**A:** P_f = P11 − (P11 − P12)(P11 + P22 − P12 − P21)^{-1}(P11 − P21).

**Q:** Two sensors both report x̂=10 with P=4 and true cross-covariance P12=3. Compute the fused variance under (a) naive information-form fusion and (b) Bar-Shalom–Campo, and say which is honest.

**A:** Naive: P_f^{-1}=1/4+1/4=0.5 → P_f=2. BC: gain (4−3)/(4+4−2·3)=1/2, P_f=4−(4−3)(1/2)(4−3)=3.5. BC's 3.5 is the honest/consistent value; the naive 2 is overconfident because the tracks are 75% correlated, so they carry nearly the same information rather than independent information.

**Q:** Give the Covariance Intersection (CI) information-form fusion equations for the fused covariance and estimate.

**A:** P_CI^{-1} = ω P11^{-1} + (1−ω) P22^{-1}, and P_CI^{-1} x̂_CI = ω P11^{-1} x̂1 + (1−ω) P22^{-1} x̂2, with ω∈[0,1] chosen to minimize tr(P_CI) or det(P_CI).

**Q:** What is the key consistency guarantee of Covariance Intersection, and what does it cost relative to Bar-Shalom–Campo?

**A:** CI is guaranteed consistent (never overconfident) for ANY actual correlation between the inputs — no knowledge of the cross-covariance is needed. The cost is that it is conservative (looser) than BC when the correlation actually is known.

**Q:** You operate a distributed multi-platform network where tracks have been re-fused and relabeled across a graph, so the true cross-covariance between any two tracks is unknown. Which fusion method is appropriate, and why is the alternative wrong here?
  a) Covariance Intersection — consistent under unknown correlation
  b) Bar-Shalom–Campo — optimal, so always use it
  c) Naive information-form fusion — simplest and unbiased
  d) Centralized measurement fusion — just average the tracks

**A:** Covariance Intersection — consistent under unknown correlation

**Q:** Why is centralized measurement-level fusion considered optimal?

**A:** Because every raw measurement enters one Kalman filter exactly once — no double counting and no correlation problem — so the result equals the Kalman filter run on all the data.

**Q:** Name two practical drawbacks of centralized measurement-level fusion versus distributed track-to-track fusion.

**A:** High communication bandwidth (every raw detection must be transmitted) and a single fusion node that is a bottleneck / single point of failure (it also needs tight time alignment of all measurements).


## Motion models: CV, CA, coordinated turn, Singer — how each sets F and Q, and the model-mismatch problem

We have a working multivariate Kalman filter (n2-matrixkf): given a state-space model $(F, H, Q, R)$ it runs the predict–update heartbeat optimally. But that *given* hides the single most consequential modelling decision in all of tracking. The filter does not know how the target moves; **we** tell it, through $F$ and $Q$. $F$ encodes our deterministic belief about the trajectory between measurements; $Q$ is our humility about that belief — the covariance of everything the deterministic part leaves out. Get these right and a noisy radar return becomes a smooth, confident track. Get them wrong and the filter either chases noise or sails serenely off the true trajectory while reporting tiny covariances. This node is about the menu of standard *kinematic* (motion) models, what $F$ and $Q$ each one implies, and the failure that no single model can escape.

**Constant velocity (CV) — the workhorse.** Newton's first law is the obvious starting point: absent forces, velocity is constant, so position grows linearly. In one spatial dimension the state is $x = [p, \dot p]^\top$ and the continuous dynamics are $\dot p = \dot p$, $\ddot p = 0$. Discretising over a sample interval $T$ gives
$$F = \begin{bmatrix} 1 & T \\ 0 & 1 \end{bmatrix}.$$
This $F$ says 'new position = old position + velocity·$T$; velocity unchanged'. But real targets *do* accelerate, so a pure CV $F$ would be a lie if $Q=0$. The fix is to admit the unmodelled acceleration as process noise. Two conventions exist, and confusing them is a classic tuning error. The **discrete white-noise acceleration (DWNA / piecewise-constant)** model assumes a constant but random acceleration $\sim \mathcal N(0,\sigma_a^2)$ across each interval, entering through the gain $\Gamma = [\tfrac{T^2}{2}, T]^\top$, so $Q = \Gamma\Gamma^\top \sigma_a^2 = \sigma_a^2\begin{bmatrix} T^4/4 & T^3/2 \\ T^3/2 & T^2 \end{bmatrix}$. The **continuous white-noise acceleration (CWNA / Wiener-velocity)** model instead drives the velocity with a white-noise process of spectral density $\tilde q$ and integrates, yielding $Q = \tilde q\begin{bmatrix} T^3/3 & T^2/2 \\ T^2/2 & T \end{bmatrix}$. Note the structural difference — $T^3/3$ versus $T^4/4$ — and the units: $\sigma_a^2$ is an acceleration *variance* (m²/s⁴), while $\tilde q$ is a *spectral density* (m²/s³). Both are correct; you just must know which one your tuning parameter feeds. *(practical)* This unit mismatch is one of the most common bugs in hand-rolled trackers: a value tuned as a variance silently dropped into a spectral-density formula (or vice-versa) is wrong by a factor with units of seconds, and the filter quietly mis-trusts its own predictions.

**Constant acceleration (CA) — when velocity changes steadily.** If targets sustain accelerations (a climbing aircraft, a launching missile), promote acceleration into the state: $x = [p, \dot p, \ddot p]^\top$ with
$$F = \begin{bmatrix} 1 & T & T^2/2 \\ 0 & 1 & T \\ 0 & 0 & 1 \end{bmatrix},$$
the kinematic Taylor expansion. Now *jerk* (the third derivative) is the unmodelled term. Under the continuous white-noise-jerk model the resulting $Q$ has top-left (position) entry $\tilde q\,T^5/20$ — the integral $\int_0^T \tilde q\,(T-s)^4/4\,ds$ of a triple integrator driven by white jerk — versus CV's $T^4/4$ scaling. CA tracks genuine accelerations far better than CV — but it pays. The extra state dimension means more to estimate from the same data, so during *non*-manoeuvring stretches a CA filter is noisier and slower to settle than CV: it 'sees' acceleration in every wiggle of measurement noise. This is the bias–variance trade-off wearing a kinematics costume.

**Coordinated turn (CT) — the nonlinear one.** Aircraft and ships rarely accelerate in a straight line; they *turn* at roughly constant speed and constant turn rate $\omega$. A constant linear acceleration cannot represent this, because turning means the acceleration vector continuously rotates (it points centripetally). The coordinated-turn model captures it: with state $[p_x, \dot p_x, p_y, \dot p_y]^\top$ and known $\omega$, the transition mixes the two velocity channels through trigonometry:
$$F(\omega) = \begin{bmatrix} 1 & \frac{\sin\omega T}{\omega} & 0 & -\frac{1-\cos\omega T}{\omega} \\ 0 & \cos\omega T & 0 & -\sin\omega T \\ 0 & \frac{1-\cos\omega T}{\omega} & 1 & \frac{\sin\omega T}{\omega} \\ 0 & \sin\omega T & 0 & \cos\omega T \end{bmatrix}.$$
The upper-right $2\times2$ block carries the minus signs and the lower-left block the plus signs — that antisymmetry is exactly the rotation of the velocity vector at rate $\omega$ (flipping the sign of $\omega$ reverses the turn direction). As $\omega \to 0$ this collapses gracefully to two decoupled CV models ($\sin\omega T/\omega \to T$, $(1-\cos\omega T)/\omega \to 0$). Crucially, when $\omega$ is *known* the model is linear. The nonlinearity bites when $\omega$ is *unknown* and must be estimated — then $\omega$ joins the state, $F$ depends on the state, and you need an EKF/UKF (n4-ekf, n4-ukf) because the transition is no longer a constant matrix.

**Singer — acceleration as a correlated random process.** CV says acceleration is white noise (uncorrelated instant to instant); CA says it is a state to be estimated (perfectly correlated, constant). Reality lives between: a pilot holds a manoeuvre for several seconds, so acceleration is *temporally correlated* but not constant. Robert Singer's 1970 model *(historical and accurate — R. A. Singer, 'Estimating Optimal Tracking Filter Performance for Manned Maneuvering Targets,' IEEE Trans. Aerospace and Electronic Systems, vol. AES-6, no. 4, pp. 473–483, July 1970)* makes acceleration a zero-mean exponentially-correlated (Ornstein–Uhlenbeck) process with autocorrelation $r(\tau) = \sigma_m^2 e^{-\alpha|\tau|}$, where $\alpha = 1/\tau_m$ is the reciprocal of the *manoeuvre time constant*. The augmented continuous model is $\dot a = -\alpha a + v$ (with the driving white noise $v$ scaled so the stationary variance is $\sigma_m^2$), giving the discrete transition
$$F_\alpha(T) = \begin{bmatrix} 1 & T & (\alpha T - 1 + e^{-\alpha T})/\alpha^2 \\ 0 & 1 & (1-e^{-\alpha T})/\alpha \\ 0 & 0 & e^{-\alpha T} \end{bmatrix},$$
with a fully-specified $Q$ matrix (the famous six $q_{ij}$ entries). Two limits make Singer intuitive: as $\alpha \to \infty$ (zero correlation time) $e^{-\alpha T} \to 0$ and Singer degenerates toward CV-with-white-acceleration; as $\alpha \to 0$ (infinite correlation time) $e^{-\alpha T} \to 1$ and it becomes CA. Singer is thus a one-knob family interpolating CV↔CA, and tuning $\alpha$ and $\sigma_m^2$ to expected manoeuvre statistics gives a single filter that handles mild manoeuvres well. *(practical)* Many production radar trackers ran a Singer-tuned filter for decades precisely because it is a single linear filter — no model bank, no mode logic — that degrades gracefully.

**Worked example — why a CV filter lags a turn.** Take a target flying east at 200 m/s that begins pulling a sustained 3 g lateral (centripetal) acceleration at $t=0$, i.e. $a = 3g \approx 29.4$ m/s², sampled at $T = 1$ s. (Note the distinction: a 3 g *load factor* in a level turn yields only a horizontal acceleration of $g\sqrt{3^2-1}\approx 27.7$ m/s² — here we mean a true lateral acceleration of 3 g.) A CV filter believes $\ddot p = 0$. Over one step its position prediction error from the neglected acceleration is the kinematic term it dropped: $\tfrac{1}{2} a T^2 = \tfrac{1}{2}(29.4)(1)^2 \approx 14.7$ m. That error feeds the innovation $\nu = z - H\hat x$. If the filter is tuned tight (small $\sigma_a^2$), the gain $K$ is small, so it corrects only a fraction of 14.7 m per scan and the *bias accumulates*: the estimate trails the true position by a growing lag, and — worse — the reported covariance $P$ stays small, so the filter is *confidently wrong*. After a few seconds the true target has left the validation gate (n8-gating) entirely and the track is lost. Pump $\sigma_a^2$ up to follow the turn and you re-admit measurement noise during the long straight legs, degrading accuracy 90% of the time to survive the 10% that manoeuvres. **This is the model-mismatch problem**, and there is no single $(F,Q)$ that wins both regimes. *(metaphorical)* It is like steering a supertanker by a fixed rudder angle: gentle enough to hold a straight course means you cannot make the harbour turn; aggressive enough to turn means you weave down every straightaway.

The escape is not a better single model but *several models run in parallel*, with a principled way to blend them by how well each currently explains the data. A constant-velocity model for cruise, a coordinated-turn (or high-$Q$) model for manoeuvres, and Bayesian mode probabilities to weight them — that is exactly the Interacting Multiple Model (IMM) algorithm of n10. *(historical and accurate — H. A. P. Blom and Y. Bar-Shalom, 'The Interacting Multiple Model Algorithm for Systems with Markovian Switching Coefficients,' IEEE Trans. Automatic Control, vol. 33, no. 8, pp. 780–783, Aug. 1988.)* So this node is the bridge: master the individual motion models and the inevitability of their mismatch here, and IMM becomes the natural next rung. The catalogue and trade-offs are laid out canonically in X. R. Li and V. P. Jilkov, 'Survey of Maneuvering Target Tracking. Part I: Dynamic Models,' IEEE Trans. Aerospace and Electronic Systems, vol. 39, no. 4, pp. 1333–1364, Oct. 2003 *(historical and accurate — citation verified)*.


**Q:** For a 1-D constant-velocity (CV) model with state $x=[p,\dot p]^\top$ and sample interval $T$, write the state-transition matrix $F$.

**A:** $F = \begin{bmatrix} 1 & T \\ 0 & 1 \end{bmatrix}$ — new position = old position + velocity·$T$, velocity unchanged.

**Q:** Two CV process-noise conventions give $Q = \sigma_a^2[[T^4/4,\,T^3/2],[T^3/2,\,T^2]]$ versus $Q = \tilde q[[T^3/3,\,T^2/2],[T^2/2,\,T]]$. Which one is the discrete white-noise acceleration (DWNA, piecewise-constant) model?

**A:** The first, with $T^4/4$ in the top-left. It models a single constant random acceleration held across each interval, so $Q = \Gamma\Gamma^\top\sigma_a^2$ with $\Gamma = [T^2/2, T]^\top$. The $T^3/3$ matrix is the continuous white-noise acceleration (CWNA / Wiener-velocity) model.

**Q:** In the two CV process-noise conventions, the DWNA tuning parameter is $\sigma_a^2$ and the CWNA tuning parameter is $\tilde q$. What physical quantity (and SI units) is each?

**A:** $\sigma_a^2$ is an acceleration variance, units m²/s⁴. $\tilde q$ is a (continuous) power spectral density, units m²/s³.

**Q:** How does the state vector of a constant-acceleration (CA) model differ from that of a constant-velocity (CV) model?

**A:** CA appends acceleration to the state: $x=[p,\dot p,\ddot p]^\top$, versus CV's $x=[p,\dot p]^\top$.

**Q:** In a constant-acceleration (CA) model, which derivative of position becomes the unmodelled process-noise term, and how does the top-left (position) entry of its continuous white-noise $Q$ scale with $T$?

**A:** Jerk (the third derivative) is the unmodelled white-noise driver. Under the continuous white-noise-jerk model the top-left $Q$ entry scales as $\tilde q\,T^5/20$ (versus CV's $T^4/4$).

**Q:** A CA filter tracks genuine accelerations better than CV. Why, then, would you NOT just always use CA — what does it cost during non-manoeuvring (straight, constant-speed) flight?

**A:** CA estimates an extra state dimension (acceleration) from the same measurements, so it has more freedom to fit measurement noise. During constant-velocity flight the true acceleration is ~0, but the filter still attributes noise-driven wiggles to acceleration, producing noisier, slower-settling estimates than a lean CV filter. It is the bias–variance trade-off: CA reduces lag-bias during manoeuvres at the cost of higher variance the rest of the time.

**Q:** In the coordinated-turn $F(\omega)$, the velocity-to-position couplings are $\sin(\omega T)/\omega$ and $(1-\cos\omega T)/\omega$. As the turn rate $\omega \to 0$, what model does $F(\omega)$ reduce to?

**A:** Two decoupled constant-velocity models: $\sin(\omega T)/\omega \to T$ and $(1-\cos\omega T)/\omega \to 0$, so each channel becomes $[[1,T],[0,1]]$ with zero cross-channel coupling. CT contains CV as its zero-turn-rate limit.

**Q:** The coordinated-turn model with a KNOWN turn rate $\omega$ is a linear model, yet CT is usually called 'the nonlinear motion model.' Resolve this — when and why does CT become nonlinear?

**A:** With $\omega$ known and fixed, $F(\omega)$ is a constant matrix, so the filter is linear (an ordinary KF works). CT becomes nonlinear when $\omega$ is UNKNOWN and is added to the state: then $F$ depends on a state component, so the transition $x_{k+1}=f(x_k)$ is a nonlinear function of the state, requiring an EKF/UKF (Jacobian/sigma points) rather than a constant $F$.

**Q:** Singer's 1970 model treats target acceleration as a zero-mean exponentially-correlated random process with autocorrelation $r(\tau) = \sigma_m^2 \, \_\_\_\_$, where the manoeuvre time constant is $\tau_m = 1/\_\_\_\_$.

**A:** $r(\tau) = \sigma_m^2 \, e^{-\alpha|\tau|}$; the manoeuvre time constant is $\tau_m = 1/\alpha$.

**Q:** Singer is described as interpolating between CV and CA via the parameter $\alpha=1/\tau_m$. Which limit of $\alpha$ gives CV-like behaviour and which gives CA, and what term in $F_\alpha(T)$ drives this?

**A:** The acceleration-persistence term is $e^{-\alpha T}$ (the bottom-right entry of $F_\alpha$). As $\alpha \to \infty$ (very short correlation time) $e^{-\alpha T}\to 0$: acceleration is uncorrelated noise, so Singer behaves like CV with white acceleration. As $\alpha \to 0$ (very long correlation time) $e^{-\alpha T}\to 1$: acceleration persists, so Singer becomes CA. Tuning $\alpha$ slides between the two.

**Q:** A tightly-tuned CV filter tracking a target that suddenly pulls a sustained turn does not just become noisier — it loses the track. Explain the failure mechanism and why it motivates IMM.

**A:** The CV model assumes zero acceleration, so each step it omits the kinematic term $\tfrac12 a T^2$. With a tight $Q$ the gain $K$ is small, so only a fraction of that error is corrected per scan and the position bias accumulates (the estimate lags the manoeuvring target). Meanwhile $P$ stays small, so the filter is confidently wrong; the true target soon falls outside the validation gate and the track is dropped. No single $(F,Q)$ wins both regimes — tight $Q$ fails turns, loose $Q$ degrades cruise. The fix is to run multiple models (e.g. CV + CT/high-Q) in parallel and weight them by how well each explains the data: the Interacting Multiple Model (IMM) algorithm.


## Gating: the validation region, Mahalanobis distance, and the chi-square threshold

*Gating turns the filter's own innovation covariance S into an ellipsoidal acceptance region around the predicted measurement; only measurements whose squared Mahalanobis distance d^2 = nu^T S^-1 nu falls below a chi-square threshold are candidates for association. This is the first, cheapest combinatorics-pruning step before any nearest-neighbour or probabilistic association.*

Up to now we have assumed a measurement and a track belong together — the filter computes the innovation $\nu = z - H\hat{x}$ and folds it in. But the moment you have clutter, false alarms, multiple targets, and missed detections, that assumption collapses. A single scan may hand you ten plots; some are the target, most are nonsense. **Which measurement do you even feed to the update?** Association is the answer, and *gating* is its gatekeeper: a cheap geometric test that, for each track, throws away the measurements that could not plausibly have come from it, leaving a short candidate list. Everything downstream — nearest neighbour, JPDA, MHT — pays a combinatorial cost in the number of candidates, so gating is the lever that keeps the whole pipeline tractable.

The key realization is that we are *already carrying* the perfect ruler for plausibility. In n3-consistency you met the innovation covariance $S = HPH^\top + R$, and the fact that a consistent filter produces innovations distributed as $\nu \sim \mathcal{N}(0, S)$. The normalized innovation squared (NIS), $d^2 = \nu^\top S^{-1} \nu$, is therefore a sum of squares of $m$ independent standard Gaussians (where $m = \dim(z)$), which is by definition a **chi-square random variable with $m$ degrees of freedom**. This is the whole idea of gating in one sentence: *a true measurement should produce a small Mahalanobis distance, and 'small' has a precise statistical meaning given by the chi-square distribution.*

So we choose a gate threshold $\gamma$ and accept a measurement $z$ into the track's validation region (also called the *gate* or *validation gate*) if and only if
$$ d^2 = \nu^\top S^{-1} \nu = (z - H\hat{x})^\top S^{-1} (z - H\hat{x}) \le \gamma. $$
Geometrically, $\{z : (z-H\hat{x})^\top S^{-1}(z-H\hat{x}) \le \gamma\}$ is an **ellipsoid** centred on the predicted measurement $H\hat{x}$. Its axes point along the eigenvectors of $S$ and its semi-axis lengths scale as $\sqrt{\gamma \, \lambda_i}$ where $\lambda_i$ are the eigenvalues of $S$. The Mahalanobis distance, introduced by P.C. Mahalanobis in his 1936 paper 'On the Generalised Distance in Statistics' *(historical and accurate)*, is exactly the right metric here because $S^{-1}$ rescales each direction by its uncertainty — a measurement two metres off along a well-known axis can be less plausible than one ten metres off along a poorly-known axis. Euclidean distance would be blind to this; Mahalanobis distance is *scale-free* and respects the filter's own confidence.

How do we pick $\gamma$? You decide what fraction of true measurements you are willing to mistakenly reject — the *gate probability* $P_G$ is the probability mass of the chi-square distribution you keep inside the gate, and you set $\gamma$ from the inverse chi-square CDF. For $P_G = 0.99$ you want the 99th percentile of $\chi^2_m$. A few values worth committing to memory: for $m=1$, $\gamma \approx 6.63$; for $m=2$, $\gamma \approx 9.21$; for $m=3$, $\gamma \approx 11.34$. (For $P_G = 0.95$ and $m=2$ it is $\gamma \approx 5.99$.) Note the deep connection to n3-consistency: the *same* NIS quantity you used to check filter consistency is the gate statistic — gating is consistency-checking applied per measurement rather than averaged over time.

**Worked example (2D position gate).** Suppose a track predicts the measurement at $H\hat{x} = (100, 50)$ m and the innovation covariance is $S = \begin{bmatrix} 4 & 0 \\ 0 & 9 \end{bmatrix}$ m$^2$ (so along-x sigma is 2 m, along-y sigma is 3 m, uncorrelated). A plot arrives at $z = (103, 56)$. The innovation is $\nu = (3, 6)$. Then $S^{-1} = \mathrm{diag}(1/4, 1/9)$ and
$$ d^2 = 3^2/4 + 6^2/9 = 2.25 + 4.0 = 6.25. $$
With a 2-DOF, $P_G = 0.99$ gate, $\gamma = 9.21$, so $6.25 \le 9.21$ and the plot is **accepted**. A second plot at $z = (107,52)$ gives $\nu=(7,2)$, $d^2 = 49/4 + 4/9 = 12.25 + 0.44 = 12.69 > 9.21$, and is **rejected** — even though in raw Euclidean terms it is closer in the y-direction, its 7 m along-x excursion is implausible given $\sigma_x = 2$ m.

Two practical refinements. First, a cheap *rectangular pre-gate* is common: reject any measurement whose component-wise residual exceeds $g\,\sigma_i$ (e.g. $g = 3$ to $4$) before doing the matrix multiply — this avoids the $S^{-1}$ computation for obvious non-candidates *(practical)*. Second, gate sizing trades two errors against each other: too tight and you lose true detections (track drops); too loose and you admit clutter, inflating the association problem and risking mis-association. As $P$ grows during a coast (missed detections), $S$ grows, the ellipsoid balloons, and *more* clutter leaks in — which is precisely when a maneuvering or lost target is most fragile. Blackman & Popoli's 'Design and Analysis of Modern Tracking Systems' (1999) treats this sizing trade in depth, including the expected number of false measurements in a gate, $\bar{N}_{FA} = \lambda V_G$, where $\lambda$ is the spatial clutter density and $V_G$ the gate volume *(practical)*. That clutter count is exactly the quantity the PDA filter in n8-jpda will need.


**Q:** Write the gating acceptance test for admitting a measurement z into a track's validation region, using the standard symbols.

**A:** Accept z iff nu^T S^-1 nu <= gamma, where nu = z - H x-hat is the innovation, S = H P H^T + R is the innovation covariance, and gamma is the chi-square gate threshold.

**Q:** Why is the gate statistic d^2 = nu^T S^-1 nu distributed as a chi-square random variable, and with how many degrees of freedom?

**A:** For a consistent filter the innovation is nu ~ N(0, S), so S^{-1/2} nu is a vector of independent standard Gaussians; the sum of their squares (which equals nu^T S^-1 nu) is by definition chi-square with m = dim(z) degrees of freedom.

**Q:** Geometrically, what shape is a validation gate, and what determines its orientation and the lengths of its axes?

**A:** It is an ellipsoid centred on the predicted measurement H x-hat; its axes align with the eigenvectors of S and its semi-axis lengths scale as sqrt(gamma * lambda_i) with lambda_i the eigenvalues of S.

**Q:** A 2D track predicts a measurement at (100,50) with S = diag(4,9). A plot arrives at (103,56). Compute d^2 and decide acceptance for a P_G=0.99 gate (gamma=9.21).

**A:** nu = (3,6); d^2 = 3^2/4 + 6^2/9 = 2.25 + 4.0 = 6.25. Since 6.25 <= 9.21, the plot is accepted.

**Q:** Why is Mahalanobis distance, rather than Euclidean distance, the correct plausibility metric for gating?

**A:** S^-1 rescales each direction by its uncertainty, so the metric is scale-free and direction-aware: a small excursion along a well-known (low-variance) axis is penalized more than a large excursion along a poorly-known (high-variance) axis. Euclidean distance ignores the filter's own confidence and would mis-rank candidates.

**Q:** What are the two competing errors when choosing the gate threshold gamma (equivalently the gate probability P_G)?

**A:** A tight gate (small gamma) risks rejecting true detections and dropping the track. A loose gate (large gamma) admits more clutter, enlarging the association problem and raising mis-association risk.

**Q:** Why does a long coast (a run of missed detections) make a fixed gate effectively worse?

**A:** With no updates, P grows during the coast, so S = HPH^T + R grows, the validation ellipsoid balloons, and more clutter leaks in — exactly when a maneuvering or lost target is most fragile.

**Q (cloze):** Cloze: The expected number of false (clutter) measurements that fall inside a validation gate is approximately N_FA = ____ times ____, the gate volume.

**A:** Cloze: The expected number of false (clutter) measurements that fall inside a validation gate is approximately N_FA = **lambda** times **V_G**, the gate volume.

**Q:** For a 2D measurement and a gate probability P_G = 0.99, what is the approximate chi-square gate threshold gamma?

**A:** About 9.21 (the 99th percentile of the chi-square distribution with 2 degrees of freedom).


## Nearest-neighbour and Global Nearest Neighbour: the 2D assignment problem, Hungarian/Munkres, and auction

*Gating leaves each track a short candidate list, but lists overlap: one measurement may gate to several tracks. Local nearest-neighbour picks each track's closest plot greedily and double-assigns; Global Nearest Neighbour instead solves a single 2D assignment problem to minimize total association cost across all tracks at once. The Hungarian/Munkres algorithm solves it optimally in strongly polynomial time (Munkres' 1957 form O(n^4); modern implementations O(n^3) after Edmonds-Karp/Tomizawa); Bertsekas's auction algorithm is an alternative with excellent average performance.*

Gating gave each track a short list of plausible measurements, but it did the job one track at a time. The lists *overlap*: a single plot often gates to two or three nearby tracks, and a single track often has several plots in its gate. We now have to commit — decide *which measurement updates which track* — and we want the globally most sensible set of pairings, not a locally greedy one. This is the **data association** decision, and the cleanest formalization is the *2D assignment problem*.

The naive approach is **(local) nearest neighbour (NN)**: for each track, pick the measurement with the smallest Mahalanobis distance in its gate and use it. This is fast and often fine in light clutter, but it has a fatal flaw — it is *greedy and per-track*, so two tracks can both grab the same measurement, and the order you process tracks in changes the answer. Imagine two aircraft flying close: track A's nearest plot is also track B's nearest plot. NN gives that plot to whichever track you happen to consider first; the other track is left starved or grabs a clutter point. There is no global accounting.

**Global Nearest Neighbour (GNN)** fixes this by insisting on a *consistent, one-to-one* assignment that is optimal across all tracks simultaneously. Build a cost matrix $C$ where $C_{ij}$ is the cost of assigning measurement $j$ to track $i$. The natural cost is the negative log-likelihood of that association, which for a Gaussian reduces to a Mahalanobis term plus a normalization constant:
$$ C_{ij} = d_{ij}^2 + \ln|2\pi S_i| = \nu_{ij}^\top S_i^{-1} \nu_{ij} + \ln|2\pi S_i|, $$
where $\nu_{ij} = z_j - H\hat{x}_i$. (The $\ln|2\pi S_i|$ term matters when tracks have very different covariances: a tight track should pay more for a large residual than a sloppy one.) Gating sets $C_{ij} = \infty$ (or a large gate-cost) for pairs outside the gate. GNN then seeks the assignment — a choice of at most one measurement per track and at most one track per measurement — that **minimizes the total cost** $\sum_{ij} C_{ij} a_{ij}$ subject to $\sum_j a_{ij} \le 1$, $\sum_i a_{ij} \le 1$, $a_{ij} \in \{0,1\}$. Because tracks can be unassigned (missed detection) and measurements can be unassigned (false alarm or new track), the matrix is padded with dummy rows/columns whose costs encode the price of leaving something unassigned.

This is the **linear assignment problem**, and crucially it is *not* NP-hard despite looking combinatorial: the constraint matrix is totally unimodular, so the LP relaxation has integer vertices and the problem is solvable exactly in polynomial time. The classic solver is the **Hungarian algorithm**, published by Harold Kuhn in 1955 (Naval Research Logistics Quarterly), who named it 'Hungarian' to honour the earlier work of the Hungarian mathematicians Dénes König and Jenő Egerváry that it builds on *(historical and accurate)*. James Munkres reviewed and refined it in 1957, showing the method runs in *strongly polynomial* time — his (and Kuhn's) form is $O(n^4)$; the now-standard $O(n^3)$ bound came later, via Edmonds and Karp and independently Tomizawa. Because of Munkres' 1957 analysis the method is also called the **Kuhn–Munkres** or **Munkres** algorithm *(historical and accurate)*. A charming footnote: in 2006 it was discovered that Carl Gustav Jacobi had essentially solved the assignment problem in the 19th century, his solution published posthumously in Latin in 1890 — so the 'Hungarian' method predates Hungary's mathematicians *(historical and accurate)*.

**Worked example.** Two tracks, two gated measurements. Cost matrix (Mahalanobis-based, ignore the log term for clarity):
$$ C = \begin{bmatrix} 2 & 8 \\ 4 & 3 \end{bmatrix}. $$
Local NN processed track-1-first: track 1 takes measurement 1 (cost 2, its minimum), then track 2 takes measurement 2 (cost 3) — total 5. Here NN happens to be fine. Now change to $C = \begin{bmatrix} 2 & 3 \\ 1 & 9 \end{bmatrix}$. Local NN, track-1-first: track 1 grabs measurement 1 (cost 2); track 2 is then forced onto measurement 2 (cost 9) — total 11. But the *global* optimum assigns track 1 -> meas 2 (cost 3) and track 2 -> meas 1 (cost 1), total **4**. The greedy choice that looked locally cheapest (track 1 -> meas 1) globally cost 7 extra. GNN finds the 4. This 'steal the cheap shared measurement' pathology is exactly why GNN beats NN whenever targets are close.

For large problems the **auction algorithm**, introduced by Dimitri Bertsekas in 1979 *(historical and accurate)*, is a popular alternative. Its intuition is economic: unassigned tracks (the 'persons') bid for measurements (the 'objects'); each object has a price that rises as it is contested; a person bids for the object giving the best value (benefit minus price), raising its price by the bid increment. Iterating bidding and assignment phases converges to an assignment satisfying *epsilon-complementary slackness*, and Bertsekas's $\epsilon$-scaling drives $\epsilon$ down to guarantee optimality. Worst-case complexity is comparable to the Hungarian method (roughly $O(n^3)$ for dense problems), but its average-case performance on randomly generated and sparse problems is typically much better, and it parallelizes naturally *(practical)*. The choice in a real tracker is pragmatic: Munkres for guaranteed optimal small/dense matrices, auction (or JV/LAPJV variants) for large sparse ones. Whichever you use, GNN still makes a *hard decision* — exactly one measurement per track — and that is its Achilles heel: in dense clutter a single wrong commitment propagates. That limitation is what motivates the soft, probabilistic association of PDA/JPDA in the next node.


**Q:** What is the key difference between local nearest-neighbour (NN) and Global Nearest Neighbour (GNN) association?

**A:** Local NN greedily gives each track its single closest gated measurement, processing tracks independently, so it can double-assign one measurement to several tracks and is order-dependent. GNN solves one global 2D assignment that enforces a one-to-one pairing minimizing total association cost across all tracks at once.

**Q:** What is the standard cost C_ij used in the GNN cost matrix for assigning measurement j to track i?

**A:** C_ij = nu_ij^T S_i^-1 nu_ij + ln|2 pi S_i|, the negative log-likelihood of the association (squared Mahalanobis distance plus a log-determinant normalization), with nu_ij = z_j - H x-hat_i.

**Q:** In the GNN cost, why include the ln|2 pi S_i| log-determinant term rather than using the Mahalanobis distance alone?

**A:** It makes tracks with different covariances comparable: for a given residual a tight (low-S) track should be penalized more than a sloppy (high-S) track. Without it, costs across tracks of different uncertainty are not on the same likelihood scale.

**Q:** Who published the Hungarian algorithm for the assignment problem, in what year, and why is it called 'Hungarian'?

**A:** Harold Kuhn published it in 1955; he named it 'Hungarian' to credit the earlier work of Hungarian mathematicians Denes Konig and Jeno Egervary on which it is based.

**Q:** What did James Munkres establish about the Hungarian method in 1957?

**A:** Munkres reviewed and refined Kuhn's method in 1957 and showed it runs in strongly polynomial time; for this the algorithm is also called the Kuhn-Munkres (or Munkres) algorithm.

**Q:** What is the time complexity of Munkres' 1957 form of the Hungarian algorithm, and how did it reach the now-standard O(n^3)?

**A:** Munkres' (and Kuhn's) form runs in O(n^4); the O(n^3) bound used by modern implementations came later, via Edmonds and Karp and independently Tomizawa.

**Q:** Given C = [[2,3],[1,9]] (rows = tracks, cols = measurements), what does greedy track-1-first NN cost versus the global optimum, and what is the GNN assignment?

**A:** Greedy track-1-first: track1->meas1 (2), forcing track2->meas2 (9), total 11. Global optimum: track1->meas2 (3) and track2->meas1 (1), total 4. GNN picks the total-cost-4 assignment.

**Q:** Why is the 2D assignment problem solvable exactly in polynomial time despite appearing combinatorial?

**A:** Its constraint matrix is totally unimodular, so the LP relaxation has integer-valued vertices; the integer optimum coincides with the LP optimum and can be found in polynomial time (e.g., by the Hungarian algorithm).

**Q:** What is the economic intuition of Bertsekas's auction algorithm?

**A:** Unassigned 'persons' (tracks) bid for 'objects' (measurements); each object holds a price that rises as it is contested, and each person bids for the object with the best benefit-minus-price. Iterating bidding/assignment converges under epsilon-scaling to an optimal assignment.

**Q:** How does the auction algorithm's worst-case complexity compare to its average-case and parallel behaviour relative to the Hungarian method?

**A:** Its worst case is comparable to the Hungarian method (roughly O(n^3) for dense problems), but its average-case performance on random and sparse problems is typically much better, and it parallelizes naturally.

**Q:** GNN produces a clean optimal one-to-one assignment. What is its fundamental weakness in dense clutter, and how does this motivate PDA/JPDA?

**A:** GNN makes a hard decision — exactly one measurement per track — so a single wrong commitment (grabbing a clutter point or swapping two close targets) propagates and can corrupt or lose the track. PDA/JPDA instead keep the association soft, weighting all gated measurements by their association probabilities, avoiding an irrevocable wrong choice.

**Q:** Two close targets share their single nearest plot. Which method risks assigning that plot inconsistently (to both or neither, depending on order), and which guarantees a one-to-one optimal split: local NN or GNN?

**A:** Local NN risks the inconsistent/order-dependent assignment; GNN guarantees a consistent one-to-one assignment minimizing total cost.


## PDA and JPDA: soft association in clutter, combined innovation, coalescence, and track existence (JIPDA)

*Rather than commit to one measurement, the Probabilistic Data Association Filter weights every gated measurement by its posterior association probability and updates with a combined innovation, plus a 'spread of innovations' covariance term reflecting association uncertainty. JPDA extends this to multiple targets by enumerating joint association events so two targets never share a measurement, at the cost of track coalescence. Integrating a track-existence probability gives IPDA/JIPDA, unifying association with track initiation and deletion.*

GNN's flaw was the hard decision: in clutter, committing to a single measurement can be exactly wrong, and the error is irreversible. The **Probabilistic Data Association Filter (PDAF)**, introduced by Yaakov Bar-Shalom and Edison Tse in their 1975 *Automatica* paper 'Tracking in a Cluttered Environment with Probabilistic Data Association' *(historical and accurate)*, refuses to decide. Its premise: if you cannot tell which of the gated measurements is the target, *use all of them*, each weighted by the posterior probability that it is the true one. This is the Bayesian move — marginalize over the unknown association rather than guess it.

Consider a single target with $m_k$ measurements inside its gate at scan $k$. Let event $\theta_i$ ($i = 1, \dots, m_k$) be 'measurement $i$ is the target-originated one', and $\theta_0$ be 'none of them is the target' (a missed detection — all gated plots are clutter). PDA computes the posterior association probabilities $\beta_i = P(\theta_i \mid Z^k)$. Modelling clutter as a spatial Poisson process of density $\lambda$ and using the Gaussian measurement likelihood, the (unnormalized) weight of $\theta_i$ is the target likelihood $\mathcal{L}_i \propto \frac{P_D}{\lambda} \mathcal{N}(\nu_i; 0, S)$ where $\nu_i = z_i - H\hat{x}$, and the weight of $\theta_0$ is $\propto 1 - P_D P_G$. Normalizing gives the $\beta_i$ with $\sum_{i=0}^{m_k} \beta_i = 1$; $\beta_0$ is the probability that *no* validated measurement is the target. The filter then forms the **combined innovation**
$$ \nu = \sum_{i=1}^{m_k} \beta_i \, \nu_i, $$
and updates the state with the ordinary Kalman gain as $\hat{x}^+ = \hat{x} + K\nu$ — a single update driven by the probability-weighted average of all residuals.

The covariance update is the subtle and beautiful part. It has *three* terms:
$$ P^+ = \beta_0 P + (1-\beta_0)\,P_c + \tilde{P}, $$
where $P_c = P - KSK^\top$ is the standard updated covariance (as if association were certain), $\beta_0 P$ keeps the larger prior covariance with weight $\beta_0$ (if probably nothing was the target, stay uncertain), and the crucial **spread-of-the-innovations** term
$$ \tilde{P} = K\left(\sum_{i=1}^{m_k} \beta_i \nu_i \nu_i^\top - \nu \nu^\top\right) K^\top $$
*inflates* the covariance to reflect the fact that we are uncertain *which* measurement was right. This term is what makes PDA honest: a confident wrong update is dangerous, so the filter widens its covariance precisely in proportion to how spread out and ambiguous the candidate measurements are. Without $\tilde{P}$ the filter would be over-confident and diverge in clutter — this term is the entire reason PDA is consistent where naive 'update with the average' is not.

**Worked example.** A single target, gate contains two plots. Innovations $\nu_1 = (1, 0)$, $\nu_2 = (3, 0)$ (looking only at the x-component for clarity), and after the likelihood/normalization step the association probabilities come out $\beta_0 = 0.2$, $\beta_1 = 0.5$, $\beta_2 = 0.3$. The combined innovation is $\nu = 0.5(1) + 0.3(3) = 0.5 + 0.9 = 1.4$ (x-component). The state moves as if it saw a residual of 1.4 — between the two plots, pulled toward the more likely one. The spread term uses $\sum \beta_i \nu_i \nu_i^\top = 0.5(1) + 0.3(9) = 0.5 + 2.7 = 3.2$ minus $\nu^2 = 1.96$, giving $3.2 - 1.96 = 1.24$ of extra innovation spread, which $K(\cdot)K^\top$ injects back into $P$. Note the variance the filter carries grows because the two plots disagreed; had both plots coincided ($\nu_1 = \nu_2$) the spread term would vanish and PDA would reduce to a standard update.

PDA tracks *one* target and treats every other target's returns as clutter — fine if targets are far apart, wrong when they are close, because one measurement could plausibly belong to two targets and PDA would (incorrectly) let it fully update both. **Joint Probabilistic Data Association (JPDA)**, due to Fortmann, Bar-Shalom and Scheffe in their 1983 *IEEE Journal of Oceanic Engineering* sonar-tracking paper *(historical and accurate)*, fixes this by enumerating *joint association events* across all targets in a cluster — feasible hypotheses in which each measurement is assigned to at most one target and each target to at most one measurement. The marginal $\beta_i^t$ for target $t$ is obtained by summing the probabilities of all joint events in which measurement $i$ is assigned to target $t$. This enforces the *exclusion constraint* (no measurement updates two targets) probabilistically, rather than the hard exclusion GNN imposes. Each target then runs a PDA-style combined-innovation update with its marginals.

JPDA's signature failure is **track coalescence**: when two targets travel close together at similar velocity, the joint events become symmetric, each target's estimate gets pulled toward the shared measurements, and the two tracks drift together and may merge into one *(historical and accurate — coalescence was documented in the JPDA literature, and bias-removal / set-JPDA variants such as JPDA* were later proposed to suppress it)*. Intuitively the soft averaging that protects a single target in clutter becomes a blurring force when two targets compete for the same plots — the estimates 'split the difference' and both end up between the true targets. This is the dual of GNN's hard-decision fragility: GNN risks a catastrophic swap, JPDA risks a gentle merge.

Finally, plain PDA/JPDA assume the target *exists* — they have no internal notion of 'is this track real?', so they cannot initiate or delete tracks on their own. **Integrated PDA (IPDA)**, by Darko Musicki, Robin Evans and Srdjan Stankovic in 1994 *(historical and accurate)*, augments the filter with a recursively-propagated *probability of track existence*, treating existence as a Markov event updated each scan from the same measurement likelihoods. A high existence probability confirms a track; a decaying one (caused by repeated missed detections, $\beta_0 \to 1$) deletes it — unifying association, initiation, and termination in one recursion. **Joint IPDA (JIPDA)**, Musicki and Evans 2004 in *IEEE Transactions on Aerospace and Electronic Systems* *(historical and accurate)*, combines the joint association events of JPDA with per-target existence probabilities, giving a principled multi-target tracker that handles clutter, target proximity, and full track lifecycle in a single Bayesian framework. This existence-probability machinery is exactly the track-score/lifecycle idea you will meet again in n11-trackmgmt.


**Q:** Who introduced the Probabilistic Data Association Filter (PDAF), in what venue and year?

**A:** Yaakov Bar-Shalom and Edison Tse, in Automatica in 1975 ('Tracking in a Cluttered Environment with Probabilistic Data Association').

**Q:** What core decision does the PDAF refuse to make, and what does it do instead?

**A:** It refuses to hard-decide which single gated measurement is the target; instead it uses all gated measurements, each weighted by its posterior association probability (a Bayesian marginalization over the unknown association).

**Q:** In PDA, what is the combined innovation and how is the state updated with it?

**A:** The combined innovation is nu = sum over gated measurements of beta_i * nu_i, the association-probability-weighted average of the individual innovations nu_i = z_i - H x-hat. The state updates with the ordinary Kalman gain: x-hat+ = x-hat + K nu.

**Q:** In PDA, what does the association probability beta_0 represent?

**A:** The posterior probability that none of the validated (gated) measurements originated from the target — i.e., a missed detection in which all gated plots are clutter.

**Q:** Write the 'spread of the innovations' term P-tilde in the PDA covariance update.

**A:** P-tilde = K (sum_i beta_i nu_i nu_i^T - nu nu^T) K^T, where nu = sum_i beta_i nu_i is the combined innovation.

**Q:** Why is the spread-of-innovations term P-tilde essential for PDA filter consistency, and when does it vanish?

**A:** It inflates P to reflect uncertainty about WHICH measurement was the true one; without it the filter would be over-confident and diverge in clutter. It vanishes when all gated innovations coincide (no disagreement to account for).

**Q:** PDA with two gated plots gives nu_1 = 1, nu_2 = 3 (x-component) and beta_0=0.2, beta_1=0.5, beta_2=0.3. Compute the combined innovation.

**A:** nu = beta_1*nu_1 + beta_2*nu_2 = 0.5*1 + 0.3*3 = 0.5 + 0.9 = 1.4. (beta_0 contributes no innovation.)

**Q:** How does JPDA extend PDA to multiple targets?

**A:** JPDA enumerates joint (feasible) association events across all targets in a cluster — each measurement assigned to at most one target and each target to at most one measurement — then computes each target's marginal association probabilities by summing over the joint events, enforcing the exclusion constraint probabilistically.

**Q:** Who introduced JPDA, and in what venue and year?

**A:** Fortmann, Bar-Shalom and Scheffe, in the IEEE Journal of Oceanic Engineering in 1983 (sonar tracking of multiple targets).

**Q:** What is track coalescence in JPDA, when does it occur, and how is it the dual of GNN's failure mode?

**A:** Coalescence is when two nearby targets' estimates are pulled toward shared measurements by the soft probability-weighted averaging, drifting together and possibly merging. It occurs when targets are close with similar velocity, making the joint events symmetric. It is the dual of GNN: GNN's hard decision risks a catastrophic track swap, whereas JPDA's soft averaging risks a gentle merge (estimates 'split the difference').

**Q:** What limitation of plain PDA/JPDA does IPDA remove, and what new state does it propagate to do so?

**A:** Plain PDA/JPDA assume the target exists and cannot initiate or delete tracks. IPDA propagates a recursive probability of track existence (a Markov event updated each scan), so a decaying existence probability deletes a track and a high one confirms it — unifying association with track initiation and termination.

**Q:** Who introduced IPDA (Integrated PDA), and in what year?

**A:** Darko Musicki, Robin Evans and Srdjan Stankovic, in 1994 (IEEE Transactions on Automatic Control).

**Q:** What does JIPDA combine, and why is it considered a principled full multi-target tracker?

**A:** JIPDA combines JPDA's joint association events with per-target probabilities of existence, so in one recursive Bayesian framework it handles clutter, target proximity, and the full track lifecycle (initiation, confirmation, deletion / false-track discrimination).

**Q:** Who introduced JIPDA (Joint IPDA), and in what venue and year?

**A:** Darko Musicki and Robin Evans, in IEEE Transactions on Aerospace and Electronic Systems in 2004.


## Multiple Hypothesis Tracking: defer the decision, let evidence prune

Every association method we have built so far commits to a decision *now*, on the current scan, and then throws away the alternatives. Global Nearest Neighbour (n8-gnn) picks the single best assignment and lives with it. JPDA (n8-jpda) is softer — it never picks one association, instead averaging over all of them in a single combined innovation — but it still *collapses* the scan: after JPDA processes scan $k$, the ambiguity of scan $k$ is gone, baked irreversibly into one Gaussian per track. Both are **single-scan** methods. The question MHT asks is heretical and simple: *why decide at all, when waiting is cheap and the future disambiguates the past?*

Consider two aircraft flying close together in clutter. On scan $k$ you receive two detections in the overlap of both gates. Which detection belongs to which track? On scan $k$ alone, the question may be genuinely unanswerable — the likelihoods are nearly equal. GNN flips a coin (picks the MAP assignment) and is wrong half the time; a wrong hard assignment corrupts the track and can never be undone. JPDA averages, pulling both track estimates toward the midpoint (the seeds of *coalescence*, which we will see in the next node). But here is the insight: on scan $k+2$ the two aircraft separate, and *in hindsight* it becomes obvious which scan-$k$ detection went with which target. The information to resolve scan $k$ exists — it just arrives later. A single-scan method cannot use it because it already destroyed the alternative. **MHT keeps every plausible interpretation alive as a branch of a hypothesis tree, carries them forward, and lets the accumulating evidence of later scans raise the probability of the correct branch and starve the wrong ones.** Decision is *deferred*, not avoided; pruning is driven by evidence, not by a coin flip on one scan.

This idea is due to **Donald B. Reid**, then at the Lockheed Palo Alto Research Laboratory, in 'An Algorithm for Tracking Multiple Targets,' *IEEE Transactions on Automatic Control*, Vol. AC-24, No. 6, pp. 843–854, December 1979 (manuscript received April 25, 1978; revised June 21, 1979; recommended by J. L. Speyer, Chairman of the Stochastic Control Committee) *(historical and accurate)*. Reid's abstract names exactly the hard cases that defeat single-scan trackers: 'initiating tracks, accounting for false or missing reports, and processing sets of dependent reports,' with 'multiple-scan correlation' — the ability of *later* measurements to aid the *prior* association — as the central new capability.

**The hypothesis tree.** A *hypothesis* is one complete, self-consistent explanation of all data received so far: an assignment of every past measurement to a source — an existing target, a brand-new target, or false alarm/clutter. When a new scan $Z(k)=\{z_1,\dots,z_{M_k}\}$ arrives, each existing hypothesis (a leaf of the tree) spawns children: one child for every legal way to assign the new measurements. Each measurement that falls in a track's gate may be assigned to that track; alternatively it may start a new target, or be declared clutter. The tree therefore branches at every scan, and the number of leaves explodes combinatorially — this is the price of deferral, and taming it (gating, clustering, pruning, k-best) is the entire engineering art of MHT, the subject of the next node.

**The probability of a hypothesis.** The whole scheme only works if we can score each branch so that evidence can prune. Reid derives this recursively by Bayes' rule. Let $\Omega_g^{k-1}$ be a parent hypothesis and $\psi_h$ a particular assignment of the current scan's measurements. The posterior of the child is

$$P(\Omega_g^{k-1},\psi_h \mid Z(k)) = \tfrac{1}{c}\, \underbrace{P(Z(k)\mid \Omega_g^{k-1},\psi_h)}_{\text{measurement likelihood}}\; \underbrace{P(\psi_h\mid \Omega_g^{k-1})}_{\text{assignment prior}}\; \underbrace{P(\Omega_g^{k-1})}_{\text{parent posterior}}$$

where $c$ is a normaliser over all children. The parent posterior is the previous scan's score — this is what makes it *recursive*, the same predict–update heartbeat (n1-bayes) lifted to whole interpretations. Substituting Reid's Poisson/binomial models for the number of detected, false, and new targets, his key result (his Eq. 16) collapses to

$$P_i^k = \tfrac{1}{c}\, P_D^{\,N_{DT}}\,(1-P_D)^{\,N_{TGT}-N_{DT}}\; \beta_{FT}^{\,N_{FT}}\; \beta_{NT}^{\,N_{NT}}\;\Big[\textstyle\prod_{m=1}^{N_{DT}} \mathcal{N}(z_m - H\bar{x};\,0,\,S)\Big]\; P_g^{k-1}.$$

(Reid writes the Gaussian as $N(Z_m - H\bar{x},\,B)$ with $B$ his innovation covariance; in the course's notation $B = S = HPH^\top + R$, so the factor is the standard innovation likelihood $\mathcal{N}(\nu;0,S)$.) Read each factor as a piece of evidence. $N_{DT}$ measurements were assigned to existing targets, so we pay $P_D$ for each ($P_D$ = probability of detection); the $N_{TGT}-N_{DT}$ targets in coverage that were *not* detected pay $(1-P_D)$ each (this is how a hypothesis is penalised for explaining a target's silence as a miss). $\beta_{FT}$ is the spatial density of false targets (clutter), raised to the number $N_{FT}$ of measurements explained as clutter; $\beta_{NT}$ is the density of new targets, raised to $N_{NT}$. And the heart of it — the product of $\mathcal{N}(\nu;0,S)$, the **Gaussian likelihood of each innovation** $\nu = z - H\bar{x}$ evaluated under its innovation covariance $S = HPH^\top+R$. This is the exact same quantity that defined the validation gate (n8-gating) and the JPDA association weights; here it scores whole hypotheses. A branch that explains the data with tight innovations, plausible detection counts, and few clutter-as-target stretches earns a high probability; an implausible branch is starved and later pruned. Note that a hypothesis assigning a measurement to clutter pays a flat $\beta_{FT}$ (a uniform $1/V$ density over the sensor volume $V$), whereas assigning it to a target pays $P_D\,\mathcal{N}(\nu;0,S)$ — so a measurement near a track's prediction strongly prefers the target branch, while an outlier prefers the clutter branch. That ratio *is* the engine of correct association.

**Worked numerical example (Reid's own track-initiation case, Section VII-A).** Reid initialises with five measurements at five times, no prior targets, new-target density $\beta_{NT}=0.5$, $P_D=0.9$, false-report density $\beta_{FT}=0.1$, position and measurement-noise variances of $0.04$. After the *first* measurement there are two hypotheses: it came from a (new) target, or it is a false report. Their relative densities are $\beta_{NT}:\beta_{FT}=0.5:0.1 = 5:1$, so the target hypothesis already sits at $5/6 \approx 83\%$ — a single point already favours 'real target' five to one, purely from the density ratio (Reid states this 5/6 vs 1/6 explicitly). As measurements two through five arrive and fall consistently near the predicted track (small innovations, large $\mathcal{N}(\nu;0,S)$), the product term compounds and the 'one real target' hypothesis climbs to **99+%** after five measurements, at which point a confirmed target is created. Reid notes a subtlety: after four measurements the most likely single hypothesis ($p\approx 88\%$) is that *all four came from one target*, while the second most likely ($p\approx 4\%$) says the first measurement was a false report and the remaining three formed the target — but *both* declare one target with nearly identical state estimates, so they are automatically combined. This is deferral working exactly as designed: the algorithm never had to commit on scan 1 to whether that first blip was clutter; by scan 5 the accumulated likelihood made the answer overwhelming. *(practical)* This is also why MHT shines at **track initiation in clutter**: a true target leaves a coherent, low-innovation trail across scans that compounds into high probability, while clutter scatters randomly and never builds a consistent branch — the multi-scan likelihood ratio is a far more powerful discriminator than any single-scan test.

*(metaphorical)* Think of MHT as a detective who refuses to name a suspect after one clue. She keeps a folder for every theory consistent with the evidence, and as each new clue lands she updates the credibility of every folder at once, quietly discarding the ones that no longer fit. The folder structure is the hypothesis tree; the credibility score is $P_i^k$; the discarding is pruning. GNN is the detective who arrests the first plausible suspect and closes the case.


**Q:** In one phrase, what is the defining strategy of Multiple Hypothesis Tracking compared to GNN and JPDA?

**A:** Defer the association decision: keep multiple competing data-association hypotheses alive across scans and let later evidence prune them, instead of committing on a single scan.

**Q:** When a new scan of measurements arrives, a leaf (existing hypothesis) of the MHT tree spawns children. What are the three possible sources MHT can assign each new measurement to?

**A:** An existing (known) target, a new target, or a false alarm / clutter.

**Q:** In Reid's hypothesis-probability recursion, what makes it recursive — i.e., which factor links the current child hypothesis to the past?

**A:** The parent hypothesis's posterior probability from the previous scan, P_g^{k-1}, multiplies into the child's score, so each new score builds on the accumulated probability of its ancestors.

**Q:** In Reid's hypothesis probability (Eq. 16), the clutter density β_FT is raised to a count, and the new-target density β_NT is raised to a count. Which count is each raised to?

**A:** N_FT (number of measurements assigned to clutter/false alarms); N_NT (number of measurements assigned to new targets)

**Q:** In Reid's hypothesis score, exactly which quantity does the Gaussian factor N(ν; 0, S) evaluate, and why is it the same object used in gating and JPDA?

**A:** It evaluates the likelihood of the innovation ν = z − Hx̂ under the innovation covariance S = HPHᵀ + R, for each measurement assigned to a target. It is the same Gaussian that defines the validation gate's Mahalanobis distance and JPDA's association weights — MHT just uses it to score whole hypotheses rather than single associations.

**Q:** Why does a hypothesis that explains a measurement as clutter compete with one that assigns it to a nearby track — and what determines which branch wins?

**A:** The clutter branch pays a flat density β_FT (uniform 1/V), while the target branch pays P_D·N(ν;0,S). The winner is set by the ratio: a measurement near the prediction has large N(ν;0,S) and favours the target branch; an outlier far from any prediction has tiny N(ν;0,S) and favours clutter. That likelihood ratio is the engine of correct association.

**Q:** In Reid's track-initiation example (β_NT=0.5, β_FT=0.1), why is a single brand-new measurement already ~83% likely to be a real target rather than clutter, before any second measurement arrives?

**A:** With one point there is no innovation history yet, so the only evidence is the density ratio of new-target to false-target: β_NT : β_FT = 0.5 : 0.1 = 5 : 1, giving the target hypothesis 5/6 ≈ 83%.

**Q:** A maneuvering pair of aircraft produces an unresolvable two-way ambiguity on scan k. Explain why MHT can recover the correct association where GNN cannot, and identify what physical fact MHT exploits.

**A:** GNN commits to one MAP assignment on scan k and discards the alternative, so a wrong guess permanently corrupts the track. MHT keeps both interpretations as sibling branches and carries them forward. When the aircraft separate on later scans, the correct branch accumulates small innovations (high ∏N(ν;0,S)) while the wrong branch accumulates large innovations and is starved/pruned. MHT exploits the fact that the information resolving scan k's ambiguity physically exists but arrives in later scans — deferral lets it be used.


## Track-oriented vs hypothesis-oriented MHT: taming the tree

Reid's MHT (n9-mht-foundations) is beautiful and, taken literally, unaffordable. Each scan multiplies the number of global hypotheses, and the tree of complete interpretations grows super-exponentially. Reid himself devotes Section V to *hypothesis reduction* — pruning unlikely branches, combining branches with similar effects, and (Section VI) clustering — because, as he puts it, 'the optimal filter developed in the previous section requires an ever-expanding memory.' Two decades of engineering converged on a different *bookkeeping* of the same idea, and on a small set of bounding tricks that make MHT run in real time. This node is about that machinery: the two architectural styles, and the four levers — gating, clustering, N-scan pruning, and k-best assignment — that bound the cost.

**Hypothesis-oriented MHT (HOMHT)** is Reid's original formulation. The unit of bookkeeping is the *global hypothesis*: a complete assignment of all measurements to all tracks/clutter/new-targets. You maintain a list of the most probable global hypotheses, and each scan you expand every one of them into its children, score them, and keep the best. The trouble is that global hypotheses are the thing that explodes — most of the combinatorial blow-up is in enumerating joint assignments that differ only in some far-away corner of the surveillance region.

**Track-oriented MHT (TOMHT)** flips the bookkeeping. Introduced by **T. Kurien** in 'Issues in the Design of Practical Multitarget Tracking Algorithms,' Chapter 3 (pp. 43–84) of Y. Bar-Shalom (ed.), *Multitarget-Multisensor Tracking: Advanced Applications*, Artech House, 1990 *(historical and accurate)*, and popularised by Samuel Blackman ('Multiple Hypothesis Tracking for Multiple Target Tracking,' *IEEE Aerospace and Electronic Systems Magazine*, Vol. 19, No. 1, pp. 5–18, Jan. 2004 *(historical and accurate)*), the unit of bookkeeping becomes the **track**, not the global hypothesis. Crucially, TOMHT *does not maintain global hypotheses from scan to scan*. Instead each potential target grows a **track tree**: a root node (the first observation that could have started this target) and a branching set of *track hypotheses* — each branch a different sequence of measurement-to-track assignments over the last several scans. All track branches sharing a common root form a **track family**. After each scan you (1) extend every track branch by gating in the new measurements, scoring each branch; (2) *then, and only at decision time*, reconstruct the best global hypothesis by choosing a mutually compatible set of branches — at most one branch per family, and no two chosen branches sharing a measurement. The expensive global object is rebuilt on demand and discarded; the persistent state is just a forest of cheap track trees. This is why essentially every fielded MHT (and MATLAB's `trackerTOMHT`) is track-oriented.

**Forming the global hypothesis = Maximum Weighted Independent Set.** Here is the elegant payoff. Build a graph: one node per track branch, its *weight* equal to that branch's track score (its log-likelihood). Connect two nodes with an edge if they are *incompatible* — i.e., they belong to the same family (two explanations of the same target) or they claim the same measurement. A valid global hypothesis is then exactly an **independent set** (no two chosen nodes share an edge), and the *most probable* global hypothesis is the **Maximum Weighted Independent Set (MWIS)** — the compatible subset of tracks with the greatest total score. MWIS is NP-hard in general, but on the sparse, clustered graphs of realistic tracking it is solved exactly or near-exactly in practice. This is the modern formulation (see Papageorgiou & Salpukas, 'The Maximum Weight Independent Set Problem for Data Association in Multiple Hypothesis Tracking,' and the graphical-model TOMHT literature) and it is why TOMHT slots so cleanly onto the assignment machinery of n8-gnn.

**The track score is a log-likelihood ratio (LLR).** To weight the MWIS nodes we need a number per branch. Take Reid's per-branch probability, take its log, and form the ratio of the 'true target' hypothesis to the 'all clutter' null hypothesis. This yields a *recursive, additive* score — exactly the property we want for a tree:

$$L(k) = L(k-1) + \Delta L(k).$$

For a **missed detection** (the gate was empty, the track coasted), the increment is purely a penalty: $\Delta L(k) = \ln(1-P_D)$. For a **detection update** with innovation $\nu = z-H\hat{x}$ and innovation covariance $S = HPH^\top+R$, the increment combines a *kinematic* term and the clutter background:

$$\Delta L(k) = \ln\!\frac{P_D}{(2\pi)^{M/2}\sqrt{|S|}\;\beta_{FT}}\; -\; \tfrac{1}{2}\,\nu^\top S^{-1}\nu,$$

where $M$ is the measurement dimension, $\beta_{FT}$ the spatial false-alarm density (Reid's clutter density; some texts write this $\beta_{FA}$), and $\nu^\top S^{-1}\nu$ the familiar Mahalanobis distance (n8-gating). A measurement that lands near the prediction (small Mahalanobis distance) *adds* score; a poor fit subtracts it; a miss leaks a fixed $\ln(1-P_D)<0$. Because the score is a log-likelihood ratio that grows with consistent detections and shrinks with misses and bad fits, **track confirmation and deletion become a Wald Sequential Probability Ratio Test (SPRT)**: confirm a track when $L(k)$ crosses an upper threshold $T_1=\ln\frac{1-\beta}{\alpha}$, delete it when $L(k)$ falls below a lower threshold $T_2=\ln\frac{\beta}{1-\alpha}$ (or, in Blackman's practical variant, when it drops by a fixed amount below its running maximum). This is the precise bridge to track management (n11-trackmgmt).

**The four levers that bound the tree.** (1) **Gating** (n8-gating): only measurements inside a track's validation region can extend that branch, so each branch produces at most a handful of children instead of $M_k$. Gating is the first and cheapest containment. (2) **Clustering**: Reid's own device (Section VI) — partition targets and measurements into independent groups that share no gated measurements, and solve each cluster's MHT separately. Because cost grows roughly exponentially in cluster size but only linearly in the number of clusters, keeping clusters small is decisive. Two clusters merge into a 'supercluster' the moment a single measurement gates to tracks in both; well-separated targets stay in tiny private clusters. (3) **N-scan pruning** (sliding-window / depth-$N$): the defining approximation that makes deferral finite. We refuse to defer forever. After forming the best global hypothesis at scan $k$, we look back $N$ scans to the root region of each track tree, find the branch the current best hypothesis descends from, and **prune away every sibling branch that disagrees with it at scan $k-N$** — collapsing the tree at the root while leaving the most recent $N$ scans still ambiguous and revisable. Reid cites Singer, Sea & Housewright's striking single-target simulation result that even $N=1$ gave near-optimal performance; typical fielded values are $N=2$ to $5$. (4) **k-best assignment (Murty)**: instead of enumerating *all* children of a hypothesis, generate only the $k$ best assignments using Murty's algorithm ('An Algorithm for Ranking all the Assignments in Order of Increasing Cost,' *Operations Research*, 16(3):682–687, 1968) layered on the Hungarian/auction solver (n8-gnn). This is the heart of Cox & Hingorani's efficient implementation — I. J. Cox and S. L. Hingorani, 'An Efficient Implementation of Reid's Multiple Hypothesis Tracking Algorithm and Its Evaluation for the Purpose of Visual Tracking,' *IEEE Trans. Pattern Analysis and Machine Intelligence*, Vol. 18, No. 2, pp. 138–150, Feb. 1996 *(historical and accurate)*, which finds the $k$-best hypotheses in polynomial time via Murty. Together these four turn a super-exponential dream into an algorithm that runs at scan rate.

**Worked example of N-scan pruning.** Suppose a track family roots at scan 1 with a blip that might be target T or clutter. By scan 3 the family has branches: B1 = {T,T,T} (real target, three detections), B2 = {clutter, T, T} (first blip false, target born at scan 2), B3 = {T, miss, T}, plus others. With $N=2$ at scan 3, we look back to scan $3-2=1$: the current best global hypothesis includes B1, whose scan-1 assignment is 'T'. We therefore prune every branch whose scan-1 assignment is *not* 'T' — B2 dies — but we keep B1 and B3 because they still differ only within the last two scans (the miss-vs-detect at scan 2 is still open). The tree is collapsed at the root (scan 1 is now committed to 'T') while scan 2's ambiguity survives for one more chance to be revised by scan 4. *(practical)* Tuning $N$ is the central MHT knob: larger $N$ recovers more of MHT's deferred-decision power (and memory cost); smaller $N$ approaches a single-scan tracker. At $N=0$ TOMHT commits every scan and degenerates to GNN; as $N\to\infty$ it approaches the optimal Bayesian filter Reid wrote down — and is just as unaffordable.

**When does MHT beat JPDA?** Both descend from the same Bayesian root, but they fail differently in the closely-spaced-target regime, and the contrast is sharp enough to be a design rule. JPDA averages over associations within a single scan; when two parallel targets are close, the combined-innovation averaging pulls their estimates toward a common midpoint — **track coalescence**: the two tracks merge and become indistinguishable. MHT makes a hard per-hypothesis decision, so its tracks never coalesce; its characteristic failure is the opposite — **track repulsion**: because each surviving hypothesis assigns the ambiguous measurement definitively to one target, the estimated separation tends to *exceed* the true separation (analysed precisely in Kropfreiter, Meyer, Crouse, Coraluppi, Hlawatsch & Willett, 'Track Coalescence and Repulsion in Multitarget Tracking: An Analysis of MHT, JPDA, and Belief Propagation Methods,' arXiv:2308.06326, published in *IEEE Open Journal of Signal Processing*, 2024; a shorter precursor appeared as Kropfreiter et al., 'Track Coalescence and Repulsion: MHT, JPDA, and BP,' FUSION 2021, arXiv:2109.01523) *(historical and accurate)*. The practical verdict: **prefer MHT when association is genuinely ambiguous over several scans and you cannot afford to merge tracks** — dense targets in heavy clutter, low $P_D$, track initiation against false alarms, crossing/parallel maneuverers — because only multi-scan deferral can use the later evidence that resolves the ambiguity. **Prefer JPDA when the target count is known and roughly fixed, computation is tight, and you mainly need robust maintenance in clutter** — its single-scan averaging is cheap, stable, and good enough when ambiguity is fleeting. MHT buys disambiguation power with bookkeeping and memory; JPDA buys cheapness and simplicity at the cost of coalescence.


**Q:** What is the unit of bookkeeping that persists from scan to scan in track-oriented MHT (TOMHT), as opposed to hypothesis-oriented MHT (HOMHT)?

**A:** In TOMHT the persistent unit is the individual track (organized into track trees / families); global hypotheses are NOT carried between scans but reconstructed on demand. In HOMHT the persistent unit is the global hypothesis itself.

**Q:** Define a 'track family' in track-oriented MHT.

**A:** The set of all track-hypothesis branches that share a common root node — i.e., all alternative measurement sequences explaining one and the same hypothesized target. A valid global hypothesis may select at most one branch from each family.

**Q:** Forming the most probable global hypothesis in TOMHT is cast as which classic graph problem, and how is the graph built (nodes, weights, edges)?

**A:** Maximum Weighted Independent Set (MWIS). Nodes are track branches weighted by their track score (log-likelihood); edges connect incompatible branches — those in the same family or claiming the same measurement. The best global hypothesis is the maximum-weight set of mutually non-adjacent (compatible) tracks.

**Q:** The MHT track score is additive: L(k) = L(k−1) + ΔL(k). For a missed detection (empty gate), the increment is ΔL(k) = ___.

**A:** ln(1 − P_D)

**Q:** In the MHT detection-update score increment, which term rewards a good kinematic fit and which represents the clutter background being competed against?

**A:** The reward/penalty for fit is the kinematic Gaussian term −½ νᵀS⁻¹ν (the Mahalanobis distance) plus its normalizer 1/((2π)^{M/2}√|S|); the clutter background is the false-alarm spatial density β_FT in the denominator of the log-ratio. The increment is essentially ln[ P_D · N(ν;0,S) / β_FT ].

**Q:** State precisely what N-scan pruning does, and what happens to TOMHT at N=0 and as N→∞.

**A:** After forming the best global hypothesis at scan k, you look back N scans, find the branch the best hypothesis descends from, and prune every sibling branch that disagrees with it at scan k−N — committing the root while leaving the last N scans revisable. At N=0 it commits every scan immediately and degenerates to single-scan GNN; as N→∞ it approaches Reid's full optimal (unaffordable) Bayesian filter.

**Q:** What role does Murty's k-best assignment algorithm play in an efficient TOMHT implementation, and which earlier algorithm does it sit on top of?

**A:** Instead of enumerating ALL children of a hypothesis, Murty's algorithm generates only the k best assignments, ranked, layered on top of the Hungarian/auction optimal-assignment solver. This is central to Cox & Hingorani's (1996) efficient MHT, which finds the k-best hypotheses in polynomial time.

**Q:** Two closely-spaced parallel targets in clutter. One tracker's pair of estimates drifts together and merges into one indistinguishable track; the other's estimates push apart so their separation exceeds the true separation. Which pathology belongs to JPDA and which to MHT, and what mechanism causes each?
  a) JPDA → coalescence (single-scan averaging of combined innovations pulls estimates to a midpoint); MHT → repulsion (hard per-hypothesis assignment forces the ambiguous measurement to one target, over-separating them)
  b) MHT → coalescence (it averages all hypotheses); JPDA → repulsion (it picks one MAP assignment)
  c) Both suffer coalescence; neither repels
  d) JPDA → repulsion; MHT → coalescence

**A:** JPDA → coalescence (single-scan averaging of combined innovations pulls estimates to a midpoint); MHT → repulsion (hard per-hypothesis assignment forces the ambiguous measurement to one target, over-separating them)

**Q:** Give the design rule for choosing MHT over JPDA: under which conditions does MHT's extra cost pay off, and when should you prefer JPDA instead?

**A:** Prefer MHT when association is genuinely ambiguous over several scans and merging tracks is unacceptable — dense targets in heavy clutter, low P_D, track initiation against false alarms, crossing/parallel maneuverers — because only multi-scan deferral can exploit the later evidence that resolves the ambiguity. Prefer JPDA when the target count is known and roughly fixed, computation is tight, and ambiguity is fleeting; its cheap single-scan averaging is robust enough, accepting some coalescence risk.


## Interacting Multiple Model (IMM): a bank of filters, Markov mixing, and the maneuver problem

*The maneuvering-target problem forces a tension: a tight constant-velocity model tracks cleanly but lags through turns, while a loose maneuver model reacts but jitters on straightaways. IMM runs a bank of filters — one per motion model — treats the active model as a hidden discrete state with a Markov transition matrix, and runs a four-step cycle each scan: mix (interaction), filter (mode-matched), update mode probabilities via innovation likelihoods, and combine. The mixing step keeps the bank's size constant (linear, not exponential, in scans), and lets the estimator cruise smoothly yet react fast.*

## The dilemma the IMM exists to dissolve

In node **n7-kinematic** you learned that there is no single motion model that fits a maneuvering target. A constant-velocity (CV) model assumes the target flies in a straight line at constant speed; its process noise $Q$ is small, so the filter is *stiff* — it trusts its own prediction, averages hard over noisy measurements, and produces a beautifully smooth, low-variance track. But the instant the target banks into a turn, that same stiffness becomes a liability: the prediction $F\hat x$ keeps flinging the estimate straight ahead, the innovations $\nu = z - H\hat x$ grow large and *biased* (they all point the same way for several scans), and the track lags behind reality, sometimes badly enough to fall out of its own gate (recall **n8-gating**). The cure seems obvious — pump up $Q$ so the filter distrusts its prediction and chases the measurements. But a high-$Q$ filter on a straight leg is a nervous wreck: it follows the measurement noise, its track wanders, and your velocity estimate is garbage. This is the **maneuvering-target problem**, and it is fundamentally a problem of *not knowing which regime you are in*. You want the stiff filter on the straightaways and the agile filter in the turns, and you want to switch between them automatically and instantly — but a switch implies you *know* when the maneuver starts, and you do not.

One classical fix is the *maneuver detector*: run a single CV filter, monitor the normalized innovation squared (NIS, from **n3-consistency**), and when it exceeds a chi-square threshold for a few scans, declare a maneuver, inflate $Q$ (or reset velocity), then deflate it again afterward. This works, but it is brittle: it is always *late* (you only detect the maneuver after the innovations have already grown), it has a hard threshold (a decision you cannot take back), and tuning the detection delay against false-alarm rate is a thankless art. The IMM replaces this hard, late, irreversible decision with a *soft, continuous, reversible* one.

## The key reframing: the model index is a hidden discrete state

Here is the conceptual leap. Instead of one model, posit a finite **bank** of $r$ models $\{M_1, \dots, M_r\}$ — say $M_1$ = CV (low $Q$) and $M_2$ = coordinated-turn or high-$Q$ CA. At each time $k$ the target is governed by *exactly one* of these, indexed by a discrete random variable $m_k \in \{1,\dots,r\}$. We never observe $m_k$ directly — it is a **hidden discrete state** riding alongside the continuous kinematic state $x$. And crucially, we model how $m_k$ evolves: it is a **Markov chain** with a known **transition probability matrix** (TPM) whose entries are
$$p_{ij} = \Pr\{m_k = j \mid m_{k-1} = i\}, \qquad \sum_j p_{ij} = 1.$$
A target that is flying straight tends to keep flying straight, so $p_{11}$ is large (e.g. 0.95); a target in a turn tends to keep turning, so $p_{22}$ is large; the off-diagonals encode the *prior rate of maneuver onset and termination*. This whole construction — a linear-Gaussian system whose coefficients $(F,Q,H,R)$ jump according to a Markov chain — is called a **Markov jump-linear system**, and estimating its state is the problem Blom and Bar-Shalom solved with the IMM. *(historical and accurate)* Henk A. P. Blom, then with the Netherlands National Aerospace Laboratory (NLR), first presented the algorithm in the paper *An efficient filter for abruptly changing systems* at the 23rd IEEE Conference on Decision and Control (CDC) in Las Vegas, December 1984; the canonical journal reference is Blom & Bar-Shalom, *The interacting multiple model algorithm for systems with Markovian switching coefficients*, IEEE Trans. Automatic Control, **33**(8):780–783, September 1988. In 2022 the IEEE Aerospace and Electronic Systems Society gave Blom and Bar-Shalom its Pioneer Award, with the citation "For development of the Interacting Multiple Model (IMM) approach to multi-model estimation and maneuvering target tracking."

## Why not just enumerate model histories? (The combinatorial wall)

The *optimal* MMSE estimator for this jump system would maintain a separate Gaussian for every possible *history* of the mode sequence $m_1, m_2, \dots, m_k$. With $r$ models that is $r^k$ hypotheses — it explodes exponentially with time, exactly the combinatorial wall you met in MHT (**n9-mht-foundations**). *(historical and accurate)* The lineage of trying to tame this is older than the IMM: D. T. Magill (*Optimal adaptive estimation of sampled stochastic processes*, IEEE TAC **10**(4):434–439, 1965) ran a **static** bank of filters for a *fixed* unknown parameter drawn from a finite set (no switching over time); G. A. Ackerson and K. S. Fu (*On state estimation in switching environments*, IEEE TAC **15**(1):10–17, 1970) introduced the **Markov switching** case and a Bayesian estimator for it. To keep that estimator from exploding, later work merged hypotheses with the **Generalized Pseudo-Bayesian** (GPB) approximations — the GPB terminology and method trace to A. G. Jaffer and S. C. Gupta (*On estimation of discrete processes under multiplicative observation noise conditions*, Information Sciences, **3**:267–276, 1971). GPB1 collapses to one Gaussian each scan (keeps only the current mode, $r$ filters); GPB2 keeps every two-step mode history ($r^2$ filters, then merges back to $r$). The IMM's genius is that it achieves **GPB2-level accuracy at GPB1-level cost** — it runs only $r$ filters, one per *current* model, yet captures the effect of the immediately preceding mode through a clever *re-initialization*. The trick that makes the bank's size constant in time is the **mixing** step.

## The four-step cycle

Let $\hat x_i(k-1)$, $P_i(k-1)$ be the output of filter $i$ from the last scan, and $\mu_i(k-1)$ its **mode probability** ($\sum_i \mu_i = 1$). One IMM cycle is:

**Step 1 — Mixing / interaction (the secret sauce).** Before each filter runs, give it a *blended* starting point built from *all* the filters, weighted by how likely it is that the target was in mode $i$ last scan *given* that it is in mode $j$ now. First the **predicted mode probabilities**
$$\bar c_j = \sum_{i=1}^{r} p_{ij}\,\mu_i(k-1),$$
then the **mixing probabilities** (a Bayes rule on the Markov chain)
$$\mu_{i|j} = \frac{p_{ij}\,\mu_i(k-1)}{\bar c_j}.$$
The **mixed initial condition** for filter $j$ is the moment-matched merge of all filters' outputs:
$$\hat x_{0j} = \sum_{i=1}^{r} \mu_{i|j}\,\hat x_i(k-1),$$
$$P_{0j} = \sum_{i=1}^{r} \mu_{i|j}\Big[P_i(k-1) + (\hat x_i(k-1)-\hat x_{0j})(\hat x_i(k-1)-\hat x_{0j})^{\mathsf T}\Big].$$
That second term — the **spread of the means** — is essential: when models disagree, the mixed covariance is inflated to honestly represent the uncertainty about *which* model was true. This is the moment of *interaction*: the filters are not run in isolation; each scan they pool information through the Markov chain. It is precisely this re-initialization that lets $r$ filters mimic the $r^2$ histories of GPB2.

**Step 2 — Mode-matched filtering.** Run each filter $j$ as an ordinary KF/EKF/UKF (whatever its model demands; this is where **n4-ekf** plugs in for nonlinear models), but *started from the mixed estimate*: predict and update $(\hat x_{0j}, P_{0j})$ with the measurement $z(k)$ using model $j$'s $(F_j, Q_j, H_j, R_j)$. Each filter also reports its **innovation** $\nu_j = z(k) - H_j \hat x_j^{-}$ and **innovation covariance** $S_j = H_j P_j^{-} H_j^{\mathsf T} + R_j$ (where $\hat x_j^{-}, P_j^{-}$ are model $j$'s prediction propagated from $\hat x_{0j}, P_{0j}$) — the very quantities you already compute in any KF (**n2-matrixkf**).

**Step 3 — Mode-probability update (the evidence vote).** Each model is scored by how well it *predicted* this measurement — its **likelihood**, the Gaussian density of its own innovation:
$$\Lambda_j = \mathcal N(\nu_j;\,0,\,S_j) = \frac{1}{\sqrt{|2\pi S_j|}}\exp\!\Big(-\tfrac12\,\nu_j^{\mathsf T} S_j^{-1}\nu_j\Big).$$
A small Mahalanobis innovation ($\nu_j^{\mathsf T}S_j^{-1}\nu_j$, the NIS from **n3-consistency**) means the model fit well, so $\Lambda_j$ is large. The updated mode probability is the prior-times-likelihood, normalized:
$$\mu_j(k) = \frac{\Lambda_j\,\bar c_j}{\sum_{\ell} \Lambda_\ell\,\bar c_\ell}.$$
This is the running *belief* over which model is active — soft, continuous, and reversible.

**Step 4 — Combination (output only).** Fuse the mode-matched estimates into the single track you report:
$$\hat x(k) = \sum_j \mu_j(k)\,\hat x_j(k), \qquad P(k) = \sum_j \mu_j(k)\Big[P_j(k) + (\hat x_j(k)-\hat x(k))(\hat x_j(k)-\hat x(k))^{\mathsf T}\Big].$$
Critically, this combined output is **for reporting only** — it is *not* fed back into the filters. Each filter $j$ carries its *own* $\hat x_j, P_j$ forward to next scan's mixing step. Collapsing to a single Gaussian and feeding it back would destroy the multi-model memory and turn the IMM back into a maneuver-detector.

## Worked numerical example (scalar, two models)

To see the heartbeat, strip it to a scalar position with two models: $M_1$ = stiff (CV-like, small $Q_1$), $M_2$ = agile (large $Q_2$), measurement $H=1$, $R=1$. TPM $p_{11}=0.95,\,p_{12}=0.05,\,p_{21}=0.10,\,p_{22}=0.90$. Suppose after a long straight leg the modes are $\mu_1=0.90,\,\mu_2=0.10$, and both filters agree the position is near $\hat x_1 = \hat x_2 = 100$.

**Mixing.** $\bar c_1 = p_{11}\mu_1 + p_{21}\mu_2 = 0.95(0.9)+0.10(0.1)=0.855+0.010=0.865$. $\bar c_2 = p_{12}\mu_1 + p_{22}\mu_2 = 0.05(0.9)+0.90(0.1)=0.045+0.090=0.135$. (They sum to 1.) Mixing probs into the *agile* filter: $\mu_{1|2} = p_{12}\mu_1/\bar c_2 = 0.045/0.135 = 0.333$, $\mu_{2|2}=p_{22}\mu_2/\bar c_2 = 0.090/0.135=0.667$. So even the agile filter is re-seeded one-third from the stiff filter's clean estimate — the bank shares information.

**Now the target maneuvers.** A measurement arrives at $z = 108$ — eight units off the straight-line prediction. The stiff filter predicted $\approx 100$ with a tight $S_1 = 1.5$, so its innovation is $\nu_1 = 8$, NIS $= 64/1.5 \approx 42.7$, and its likelihood carries the factor $\exp(-\tfrac12\cdot42.7)=\exp(-21.3)\approx 5.4\times10^{-10}$ — astronomically small. The agile filter, with large $Q_2$, predicted $\approx 100$ but with a fat $S_2 = 25$, so $\nu_2 = 8$, NIS $= 64/25 = 2.56$, and its likelihood carries $\exp(-\tfrac12\cdot2.56)=\exp(-1.28)\approx 0.278$. To compare the two on equal footing we keep the *full* Gaussian density $\Lambda_j=\frac{1}{\sqrt{2\pi S_j}}\exp(-\tfrac12\,\mathrm{NIS}_j)$: $\Lambda_1\approx \frac{1}{\sqrt{2\pi(1.5)}}(5.4\times10^{-10})\approx 1.8\times10^{-10}$ and $\Lambda_2\approx \frac{1}{\sqrt{2\pi(25)}}(0.278)\approx 0.0222$. The unnormalized weights are $\Lambda_1\bar c_1 \approx (1.8\times10^{-10})(0.865) \approx 1.5\times10^{-10}$ versus $\Lambda_2\bar c_2 \approx (0.0222)(0.135) \approx 3.0\times10^{-3}$. Normalizing: $\mu_2(k) \approx 0.99999$. **In a single scan the belief has flipped almost entirely to the agile model** — because the stiff model's huge, badly-scaled innovation made it exponentially implausible. The combined output is now essentially the agile filter's estimate, which jumped toward $108$. That is *react fast*. When the maneuver ends and the straight-line measurements return, the agile filter's wide $S$ keeps its likelihood merely *good* while the stiff filter's tight $S$ makes it *excellent*, so $\mu_1$ climbs back and the output returns to the smooth track. That is *cruise smoothly*. The exponential sensitivity of the Gaussian likelihood to a poorly-normalized innovation is the engine of the IMM's fast reaction; the Markov TPM and the mixing step are what give it smooth, stable cruising and a memory that the bare maneuver-detector lacks.

## Why it cruises smoothly yet reacts fast — and where it fails

The smoothness comes from three places: the soft probabilistic blend (no hard switch to overshoot through), the TPM's diagonal *inertia* ($p_{jj}$ near 1 resists spurious mode flips from single noisy scans), and the stiff filter's low variance dominating the combination during straight legs. The fast reaction comes from the *likelihood ratio's* exponential sensitivity, demonstrated above. The mixing step is what makes it cheap and stable: it bounds the bank at $r$ filters forever, and it injects the stiff filter's good estimate into the agile filter (and vice-versa) so neither drifts. *(practical)* Two tuning levers dominate field performance: the **TPM diagonals** (too high $\Rightarrow$ sluggish maneuver onset; too low $\Rightarrow$ jittery, falsely-switching track) and the **model set** (the agile model's $Q_2$ must be large enough to *contain* the real maneuver inside its gate, or every model fits badly and the IMM cannot help). A common, robust design is a 2- or 3-model bank: one low-$Q$ CV for cruise, one high-$Q$ CV or CA for maneuver, sometimes a coordinated-turn model for sustained banking. *(metaphorical)* Think of the IMM as a panel of specialist commentators watching the same game: a conservative one who assumes nothing surprising will happen, and an excitable one who expects chaos. Each scan you ask all of them to predict the next play, then re-weight your trust by who called it right — and before the next play you let them confer (mixing) so the excitable one borrows the conservative one's steady read of the score. You report the trust-weighted consensus, but you never silence anyone.


**Q:** In the IMM framework, the active motion model at time $k$ is treated as what kind of quantity, and how is its evolution over time modeled?

**A:** It is treated as a hidden discrete state (the mode index $m_k \in \{1,\dots,r\}$), and its evolution is modeled as a Markov chain with a known transition probability matrix (TPM) of entries $p_{ij}=\Pr\{m_k=j\mid m_{k-1}=i\}$.

**Q:** Name the four steps of one IMM cycle, in order.

**A:** (1) Mixing/interaction — compute mixing probabilities and mixed initial conditions; (2) mode-matched filtering — run each filter from its mixed start; (3) mode-probability update — re-weight modes by their innovation likelihoods; (4) combination — fuse the mode estimates into the reported output.

**Q:** The mixing probability is $\mu_{i|j} = p_{ij}\,\mu_i(k-1)/\bar c_j$, where the normalizer $\bar c_j = \sum_i p_{ij}\,\mu_i(k-1)$ is the predicted (a priori) mode probability for model $j$.

**A:** p_{ij}\,\mu_i(k-1); predicted (a priori) mode probability

**Q:** The mixed-covariance formula for filter $j$ adds, beyond the weighted sum of the $P_i$, a 'spread of the means' term $\sum_i \mu_{i|j}(\hat x_i - \hat x_{0j})(\hat x_i - \hat x_{0j})^{\mathsf T}$. Why is this term necessary?

**A:** Because the mixed initial condition is a moment-matched merge of several Gaussians whose means disagree; the spread-of-the-means term inflates the covariance to honestly capture the uncertainty about WHICH model was active. Omitting it makes the filter overconfident (covariance too small) when the models disagree.

**Q:** How is each model's likelihood $\Lambda_j$ computed in the IMM mode-probability update?

**A:** $\Lambda_j$ is the Gaussian density of that filter's own innovation evaluated at zero: $\Lambda_j = \mathcal N(\nu_j;\,0,\,S_j)$, using its innovation $\nu_j$ and innovation covariance $S_j$.

**Q:** Given each model's likelihood $\Lambda_j$ and predicted mode probability $\bar c_j$, how is the updated mode probability $\mu_j(k)$ formed?

**A:** It is the normalized product of likelihood and predicted mode probability: $\mu_j(k) = \Lambda_j \bar c_j / \sum_\ell \Lambda_\ell \bar c_\ell$ — i.e. Bayes' rule with $\bar c_j$ as prior and $\Lambda_j$ as likelihood.

**Q:** After the combination step produces the fused output $\hat x(k), P(k)$, is this fused estimate fed back into the individual filters as their next starting state? Why or why not?

**A:** No. The combined output is for reporting only. Each filter carries its OWN $\hat x_j, P_j$ forward to the next mixing step. Feeding the single collapsed Gaussian back would erase the multi-model memory, destroying the IMM's ability to keep distinct mode hypotheses alive — it would degenerate toward a single-model filter / maneuver detector.

**Q:** The IMM runs only $r$ filters yet rivals GPB2's accuracy, while the optimal estimator needs $r^k$ hypotheses. Which single step collapses the would-be exponential growth to a constant bank size, and what does it accomplish that a naive 'run $r$ independent filters' scheme (GPB1) cannot?

**A:** The mixing/interaction step. It re-initializes each filter $j$ each scan with a Markov-weighted blend $\hat x_{0j}=\sum_i \mu_{i|j}\hat x_i$ of ALL the previous filters' outputs (plus the spread-of-means covariance). This injects the effect of the immediately-preceding mode into the current filter — capturing the two-step mode history GPB2 enumerates explicitly — while keeping exactly $r$ filters. GPB1, lacking this interaction, just collapses to one Gaussian and re-seeds every filter identically, losing the cross-model memory and tracking maneuvers worse.

**Q:** Mechanistically, why can the IMM 'react fast' to a sudden maneuver — i.e. why can the mode probability swing almost entirely to the agile model in a single scan?

**A:** Because the mode likelihood is a Gaussian of the innovation, it is EXPONENTIALLY sensitive to the Mahalanobis innovation (NIS) $\nu_j^{\mathsf T}S_j^{-1}\nu_j$. When a maneuver makes the stiff model's innovation large relative to its tight $S$, its NIS blows up and $\Lambda$ collapses by orders of magnitude, so the Bayes normalization shifts almost all mode probability to the agile model in one scan.

**Q:** Mechanistically, why does the IMM 'cruise smoothly' on a straight leg rather than jittering between modes?

**A:** Three reasons: (1) the soft probabilistic blend means no hard switch to overshoot through; (2) the TPM diagonals ($p_{jj}\approx1$) supply mode inertia, resisting spurious flips driven by a single noisy scan; (3) on straight legs the stiff (low-variance) model's tight $S$ makes its likelihood best, so it earns the high mode probability and its low-variance estimate dominates the combined output.

**Q:** Choose the description of how raising the TPM diagonal entries $p_{jj}$ (e.g. from 0.90 to 0.99) affects IMM behavior.
  a) Increases mode-switching inertia: the estimator is slower to abandon its current mode, giving smoother cruising but a more sluggish, delayed response to maneuver onset.
  b) Speeds up maneuver detection because each model is trusted more, so the agile model engages sooner.
  c) Has no effect on dynamics; the TPM only normalizes the output covariance.
  d) Forces a hard switch to a single model once a threshold is crossed, like a maneuver detector.

**A:** Increases mode-switching inertia: the estimator is slower to abandon its current mode, giving smoother cruising but a more sluggish, delayed response to maneuver onset. — Larger diagonals make $\bar c_j=\sum_i p_{ij}\mu_i$ favor staying in the current mode, so a single off-model measurement struggles to move the probabilities — smoother but more sluggish. Choice 2 inverts the effect; choice 3 is false (the TPM drives the predicted mode probabilities, not just normalization); choice 4 describes a maneuver detector, not the soft IMM.


## Track lifecycle & management: initiation, M-of-N, SPRT, track score, deletion

*Track management is the bookkeeping layer that decides which hypothesized tracks are born, confirmed, coasted, and killed. It turns the per-scan association machinery (gating, GNN/JPDA) into a stable picture of how many targets exist. The central tool is a running log-likelihood-ratio track score updated each scan; M-of-N is its crude integer cousin and Wald's SPRT is its statistically optimal continuous form, with confirmation and deletion thresholds set from desired error probabilities.*

Everything before this node assumed the tracks already existed. Gating (n8-gating) decided which measurements *could* update a given track; GNN and JPDA (n8-gnn, n8-jpda) decided which measurement *does* update it. But none of that machinery answers the prior question: which tracks deserve to exist at all? A radar scan returns dozens of detections, most of them clutter. Some are real targets you have never seen. Some are real targets you have, momentarily, stopped seeing. Track management is the lifecycle layer that turns a stream of associations into a stable count of objects: it decides which hypothesized tracks are *born*, which are *confirmed* and shown to the operator, which are *coasted* through a missed detection, and which are *killed*. This is the difference between a tracker and a flickering mess of clutter.

**Why we need it: the asymmetry of errors.** Initiating a track from a single unassociated detection is reckless — most single detections are false alarms, so you would flood the display with phantom tracks. But waiting too long to initiate loses real targets during the most critical seconds. Conversely, deleting a track the instant it misses a detection throws away targets that merely dipped below the detection threshold; never deleting fills memory with dead tracks. Every management rule is a tuned trade-off between *false track confirmation* (declaring clutter a target) and *true track loss* (failing to confirm or prematurely deleting a real target). The natural state machine has four states: **tentative** (just initiated, not yet trusted), **confirmed** (trusted, displayed), **coasting** (confirmed but currently missing detections, propagated on the motion model alone), and **deleted**. A tentative track is promoted to confirmed or dropped; a confirmed track that stops associating coasts, then is deleted if it stays silent too long. Robert Sittler's 1964 paper "An optimal data association problem in surveillance theory" (IEEE Trans. Mil. Electron. 8(2):125–139) already framed exactly these *tentative*, *confirmed*, and *established* track states and posed track confirmation as maximum-likelihood estimation in a form suited to sequential, real-time computation — the conceptual seed of everything below. *(historical and accurate)*

**Rung 1 — the crude integer rule: M-of-N.** The simplest confirmation logic counts hits. After a tentative track is initiated, look at the next $N$ opportunities (scans, or beams revisited at the predicted position); confirm the track if it associates a detection on at least $M$ of them. A common air-surveillance rule is *2-of-3* or a two-stage *(2/2 then 2/3)* logic. M-of-N is beloved because it is trivial to implement and its statistics are easy: if the per-scan probability of detection is $P_D$ and the per-gate probability that a clutter detection falls in the gate is $P_{FA}$, the probability of confirming a true target in an $M$-of-$N$ window is $\sum_{k=M}^{N}\binom{N}{k}P_D^{k}(1-P_D)^{N-k}$, and the probability of confirming pure clutter is the same expression with $P_{FA}$ substituted for $P_D$. The weakness is that M-of-N is *information-throwing*: it reduces each scan to a binary hit/miss, ignoring **how good** the association was. A detection 0.1σ from the prediction and one 2.9σ away (both inside the gate) count identically; a strong-SNR return and a marginal one count identically. It also implicitly assumes a fixed scan cadence. We want a confirmation rule that uses the *quality* of each association and accumulates evidence optimally over time.

**Rung 2 — the track score as accumulated evidence (the LLR).** Reframe confirmation as a hypothesis test. Let $H_1$ = "this track is a real target" and $H_0$ = "this sequence of detections is false alarms / not a target." After observing the association history, the natural statistic is the **likelihood ratio** $\Lambda = p(\text{data}\mid H_1)/p(\text{data}\mid H_0)$, and because evidence multiplies across independent scans, its logarithm — the **log-likelihood ratio (LLR)**, or *track score* $L$ — simply *adds*:
$$L(k) = L(k-1) + \Delta L(k).$$
This recursion (Blackman 2004) is the heart of modern track management. The increment $\Delta L(k)$ rewards a track for collecting a detection that fits well and penalizes it for missing one. With probability of detection $P_D$, false/extraneous-measurement spatial density $\beta_{FA}$ (expected clutter per unit measurement volume), measurement dimension $M$, innovation $\nu = z - H\hat{x}$ and innovation covariance $S = HPH^{\top}+R$, the standard increments are:
$$\Delta L_{\text{detect}} = \ln\!\frac{P_D}{(2\pi)^{M/2}\sqrt{|S|}\,\beta_{FA}} - \tfrac{1}{2}\,\nu^{\top}S^{-1}\nu, \qquad \Delta L_{\text{miss}} = \ln(1-P_D).$$
Notice the anatomy: the term $-\tfrac12\nu^{\top}S^{-1}\nu$ is exactly the (negative half) Mahalanobis distance from gating (n8-gating), so a tight association adds more score; $\beta_{FA}$ in the denominator means evidence is stronger when clutter is sparse (a detection in an empty region is more meaningful); and $\ln(1-P_D)<0$ steadily bleeds score from a coasting track. The score is initialized with $L(0)=\ln(\beta_{NT}/\beta_{FA})$, the log-ratio of the new-target density $\beta_{NT}$ to the false-target density $\beta_{FA}$ — the prior odds that an unassociated detection started a real track rather than clutter. (Dimensionally, the $\beta$ densities in the denominator carry the inverse-volume units that cancel the $\sqrt{|S|}$ volume factor, so the resulting score is dimensionless — the property that lets scores from differently-sized batches be compared.) This same LLR is the kinematic part of the Reid (1979) hypothesis-probability score used by MHT (n9), so track management and MHT scoring are the *same* arithmetic. The score is dimensionless and, when $L$ is read as a log-odds, converts back to a probability of being a true target via $P_T = e^{L}/(1+e^{L})$. *(practical)*

**Rung 3 — when to stop accumulating: Wald's SPRT.** A fixed window (M-of-N) wastes time on obvious cases and rushes ambiguous ones. Abraham Wald's **Sequential Probability Ratio Test** answers "how many observations are enough?" optimally. Wald developed the SPRT during World War II (circa 1943) at Columbia University's Statistical Research Group for munitions/quality-control inspection; it was deemed so valuable that it was classified until the war's end and published in his 1947 book *Sequential Analysis* (Wiley). *(historical and accurate)* The idea: don't fix the sample size — keep accumulating the LLR and stop the *moment* it crosses one of two thresholds. Confirm the track ($H_1$) if $L \ge T_1$; delete it ($H_0$) if $L \le T_2$; otherwise keep it tentative and take another look. The thresholds come from the two error probabilities you are willing to tolerate — $\alpha$ = probability of confirming a false track, $\beta$ = probability of deleting a true track. Wald's (approximate) bounds, ignoring the small overshoot when the score steps past a threshold between scans, are:
$$T_1 = \ln\!\frac{1-\beta}{\alpha}, \qquad T_2 = \ln\!\frac{\beta}{1-\alpha}.$$
These are exact as inequalities and approximate as equalities (boundary overshoot makes the realized error rates slightly better than $\alpha,\beta$). Thus $T_1>0$ (need positive evidence to confirm) and $T_2<0$ (need negative evidence to delete), with a *gray zone* between where the track stays tentative. Wald and Wolfowitz proved in 1948 ("Optimum character of the sequential probability ratio test," Annals of Math. Stat. 19:326–339) that among all tests with the same error probabilities, the SPRT *minimizes the expected number of observations* under both hypotheses — it is decision-theoretically optimal. *(historical and accurate)* Van Keuk applied exactly this to radar track formation in "Sequential track extraction" (IEEE T-AES 34(4):1135–1148, 1998). In practice the score is often *clipped* so a long-confirmed track cannot bank unlimited credit (which would make it un-deletable), and a separate, faster-decaying deletion logic or an $N$-consecutive-misses rule backs up the SPRT deletion threshold.

**Worked example.** A radar has $P_D=0.9$, measurement dimension $M=2$ (range, azimuth), clutter density $\beta_{FA}=10^{-4}$ per unit area, new-target density $\beta_{NT}=10^{-5}$. We want false-confirm probability $\alpha=0.01$ and true-delete probability $\beta=0.01$. Thresholds: $T_1=\ln(0.99/0.01)=\ln 99\approx +4.60$, $T_2=\ln(0.01/0.99)\approx -4.60$. Initial score $L(0)=\ln(10^{-5}/10^{-4})=\ln(0.1)\approx -2.30$. Now suppose three good detections arrive, each with normalized innovation squared $\nu^{\top}S^{-1}\nu = 1.0$ and $\sqrt{|S|}=50$ (units$^2$). Each detect increment: $\ln\!\big(0.9 / (2\pi \cdot 50 \cdot 10^{-4})\big) - 0.5 = \ln(0.9/0.0314) - 0.5 = \ln(28.6) - 0.5 \approx 3.35 - 0.5 = +2.85$. After three hits: $L = -2.30 + 3(2.85) = -2.30 + 8.56 = +6.26 \ge T_1$. The track is **confirmed** after 3 scans. Now suppose instead a confirmed track at $L=+6.26$ starts missing: each miss adds $\ln(1-0.9)=\ln(0.1)=-2.30$. After miss 1: $+3.96$; miss 2: $+1.66$; miss 3: $-0.64$; miss 4: $-2.95$; miss 5: $-5.25 \le T_2$. The track **coasts** through misses 1–4 and is **deleted** on the fifth consecutive miss. Notice the asymmetry the score encodes naturally: a clean detection buys $\approx +2.85$ but a miss costs only $-2.30$, so a healthy track tolerates several misses before death — exactly the coasting behavior we wanted, derived rather than hand-tuned.

This is the payoff of the first-principles ladder: M-of-N is the SPRT with both thresholds collapsed onto a hit-count and all association quality discarded; the LLR track score is the SPRT statistic computed exactly; and the four-state lifecycle (tentative → confirmed → coasting → deleted) is just the SPRT's continue/accept/reject regions plus a memory of how long a confirmed track has been silent.


**Q:** Name the four states in a typical track lifecycle state machine.

**A:** Tentative, confirmed, coasting, and deleted. A track is initiated tentative, promoted to confirmed once enough evidence accumulates, coasts (propagated on the motion model) through missed detections, and is deleted when its score decays or it stays silent too long.

**Q:** In an M-of-N track confirmation rule, what do M and N represent?

**A:** N is the number of look opportunities (scans or revisits) in the confirmation window, and M is the minimum number of those that must yield an associated detection to confirm the track. E.g. 2-of-3 confirms after detections on any 2 of the next 3 scans.

**Q:** Write the recursive update for the track score (log-likelihood ratio) L across scans.

**A:** L(k) = L(k-1) + ΔL(k). The track score is the accumulated log-likelihood ratio that the track is a real target rather than false alarms; because independent evidence multiplies, its logarithm adds, so each scan's contribution is just summed onto the running score.

**Q:** In the track-score recursion, what is the sign of the increment ΔL for a well-fitting detection versus a missed detection, and what is the miss increment exactly?

**A:** A well-fitting detection gives a positive increment (larger when the innovation is small and clutter density is low), raising the score. A missed detection gives a negative increment equal to ln(1-P_D), lowering the score.

**Q:** Complete the detection score increment. The term that depends on the association quality is the negative half of the normalized innovation squared / Mahalanobis distance, ν^T S^{-1} ν, and the clutter density β_FA appears in the denominator inside the log, so a detection in a sparse-clutter region adds more score.

**A:** normalized innovation squared / Mahalanobis distance, ν^T S^{-1} ν; β_FA appears in the denominator inside the log; more

**Q:** In Wald's SPRT applied to track management, give the (approximate) confirmation threshold T1 and deletion threshold T2 in terms of the false-confirmation probability α and the true-track-deletion probability β.

**A:** T1 = ln((1-β)/α) for confirmation (positive), and T2 = ln(β/(1-α)) for deletion (negative). The track score must rise above T1 to confirm or fall below T2 to delete; between them it stays tentative/coasting. These are Wald's bounds — exact as inequalities, approximate as equalities because of boundary overshoot.

**Q:** What is the initial track score L(0) set to, and what prior odds does it encode?

**A:** L(0) = ln(β_NT / β_FA), the log-ratio of the new-target spatial density β_NT to the false-target (clutter) density β_FA. It encodes the prior odds that a fresh unassociated detection arose from a genuine new target versus from clutter.

**Q:** Why does the SPRT-based track score achieve fast-yet-reliable confirmation where a fixed M-of-N rule struggles? Contrast the two precisely.

**A:** M-of-N collapses each scan to a binary hit/miss, discarding association quality and SNR, and fixes the decision horizon at N scans — so it confirms an obvious target no faster than an ambiguous one and cannot adapt to clutter level. The SPRT score accumulates the actual log-likelihood of each association (rewarding tight, low-clutter detections more), and Wald & Wolfowitz (1948) proved it minimizes the expected number of observations for fixed error probabilities α, β. It stops the instant evidence crosses a threshold: strong tracks confirm in fewer scans, weak ones wait, and the thresholds are derived from desired error rates rather than tuned by hand.

**Q:** A confirmed track with a high banked score begins missing detections. Why is it common practice to clip (cap) the maximum track score, and what failure does an uncapped score cause?

**A:** Each missed detection only subtracts ln(1-P_D), so an uncapped score that has banked very high credit during a long detection run would take an impractically large number of consecutive misses to fall below the deletion threshold T2 — the track becomes effectively un-deletable and coasts forever (a stale ghost track). Clipping the score (or adding an N-consecutive-misses deletion backstop) bounds the coast time so a vanished target is dropped promptly.

**Q:** The track-confirmation LLR is the same arithmetic as which score used elsewhere in the tracker?

**A:** It is the kinematic part of the Reid (1979) hypothesis-probability / hypothesis score used in MHT (n9): both add a per-scan log-likelihood term built from P_D, the clutter density, and the Gaussian innovation term -½ν^T S^{-1}ν. Track management is the single-track special case of the same likelihood-ratio bookkeeping MHT applies to whole hypotheses.


## Target typing/classification & feature-aided tracking (hidden discrete state)

*Targets carry identity, not just kinematics. Treating target class as a hidden discrete state estimated by a Bayes recursion over feature measurements (RCS, JEM, HRR profile) yields feature-aided tracking: class probabilities update like a discrete Bayes filter, class-conditioned motion models tighten association, and clean association in turn purifies the feature stream — a bidirectional coupling that disambiguates closely spaced targets a kinematics-only tracker cannot separate.*

So far the state $x$ has been purely kinematic — position, velocity, maybe acceleration — and the only thing a measurement told us was *where* the target is. But real sensors report more than location. A radar return has an amplitude (radar cross section, RCS); a coherent radar sees periodic spectral lines from spinning turbine or propeller blades (jet engine modulation, JEM); a wideband radar resolves the target into a high-range-resolution (HRR) profile of scattering centers along the line of sight; an ESM receiver reports emitter frequency and pulse-repetition interval. These are **features**, and they carry *identity*: a fighter, an airliner, a helicopter, a bird, and a cruise missile have different RCS distributions, different JEM line spacings (blade count × rotation rate), different HRR signatures, and different flight envelopes. Target typing is the problem of inferring this identity; feature-aided tracking is the problem of using it to track better. The conceptual leap from n11-trackmgmt is that we now augment the state with a component that is not a continuous position but a *discrete label*.

**Why class is a hidden discrete state.** The kinematic state lives in $\mathbb{R}^n$ and we estimate it with a Kalman-family filter (n2-matrixkf onward). Class lives in a finite set $\{c_1,\dots,c_m\}$ — "fighter, airliner, helicopter, clutter" — and we never observe it directly; we observe noisy features that *depend* on it. This is the textbook structure of a **hidden discrete state**, and the right estimator is a discrete Bayes recursion that maintains a posterior probability mass function over classes, $\mu_c(k) = P(\text{class}=c \mid \text{features through } k)$. The recursion mirrors the predict–update heartbeat of n1-bayes, but on a finite alphabet, so the integral becomes a sum:
$$\mu_c(k) = \frac{1}{C}\, p\big(f_k \mid \text{class}=c\big)\,\mu_c(k-1), \qquad C = \sum_{c'} p\big(f_k \mid \text{class}=c'\big)\,\mu_{c'}(k-1),$$
where $f_k$ is the feature measurement at scan $k$ and $C$ is the normalizing constant that keeps $\sum_c \mu_c = 1$. The likelihood $p(f_k\mid c)$ is the classifier's model of how class $c$ produces feature $f_k$. For a discrete feature output (e.g. a classifier that emits a declared type), this likelihood is literally a **confusion matrix** entry: $p(\text{declared}=d \mid \text{true}=c)$, estimated offline from labelled data. For a continuous feature like RCS in dB, it is a class-conditional density (often log-normal). Note the deep structural parallel to the IMM (n10): the IMM mixes a bank of *kinematic* models with Markov transition probabilities; class estimation mixes a bank of *type* hypotheses. The difference is that target type is (usually) static — a fighter does not turn into an airliner — so the Markov transition matrix is the identity, or near-identity with a tiny leak to allow recovery from a wrong early commitment. *(metaphorical: think of it as an "IMM whose modes are identities, not maneuvers, and which almost never switches.")*

**Worked example — RCS-driven typing.** Two classes: airliner ($c_1$) with mean RCS $\mu_1 = 20$ dBsm and fighter ($c_2$) with $\mu_2 = 5$ dBsm, each with class-conditional standard deviation $\sigma = 5$ dB (log-normal RCS, so Gaussian in dB). Start with a flat prior $\mu_1(0)=\mu_2(0)=0.5$. Scan 1 measures RCS $f_1 = 8$ dBsm. Likelihoods (Gaussian density up to the common constant): $p(f_1\mid c_1) \propto \exp(-(8-20)^2/(2\cdot 25)) = \exp(-144/50)=\exp(-2.88)=0.0561$; $p(f_1\mid c_2)\propto \exp(-(8-5)^2/50)=\exp(-9/50)=\exp(-0.18)=0.835$. Posterior: $\mu_2(1) = (0.835\cdot0.5)/(0.835\cdot0.5 + 0.0561\cdot0.5) = 0.4175/0.4456 = 0.937$. One look already says "93.7% fighter." Scan 2 measures $f_2 = 18$ dBsm (a glint — RCS fluctuates scan-to-scan, the Swerling phenomenon): $p\propto\exp(-(18-20)^2/50)=\exp(-0.08)=0.923$ for $c_1$, $\exp(-(18-5)^2/50)=\exp(-3.38)=0.034$ for $c_2$. Update from the prior $\mu(1)=(0.063, 0.937)$: numerator$_1 = 0.923\cdot0.063=0.0582$, numerator$_2=0.034\cdot0.937=0.0319$; $\mu_1(2)=0.0582/(0.0582+0.0319)=0.646$. The single high-RCS glint dragged the belief back toward airliner — illustrating *why one feature look is rarely decisive* and why accumulating features over many scans (exactly as the kinematic filter accumulates positions) is the whole point. It also shows the danger of a static transition matrix with no leak: had we hard-committed to "fighter" after scan 1, scan 2's evidence could never be admitted.

**The payoff is bidirectional: class helps association, association helps class.** This is the central insight of feature-aided tracking, formalized by Bar-Shalom, Kirubarajan, and Gokberk in "Tracking with Classification-Aided Multiframe Data Association" (IEEE T-AES 41(3):868–878, July 2005). *(historical and accurate)* Recall the association likelihood from gating and JPDA (n8): a measurement is scored against a track by its kinematic Gaussian, $\propto \exp(-\tfrac12\nu^\top S^{-1}\nu)/\sqrt{|S|}$. Feature-aided tracking *multiplies in a feature term*: the joint measurement-to-track likelihood becomes (kinematic likelihood) × (feature likelihood given the track's class belief). Concretely, the association score gains a factor $\sum_c \mu_c \, p(f \mid c)$ — a measurement whose feature matches the track's established type is favored; one whose feature contradicts it is penalized even if it is kinematically plausible. **This is how feature-aided tracking separates two targets a kinematics-only tracker cannot.** Two aircraft crossing at the same point produce two detections inside both tracks' gates; kinematic geometry alone is ambiguous (the classic track-coalescence and identity-swap failure of n8-jpda). But if one track has accumulated "helicopter" (low, distinctive JEM) and the other "jet" (high-frequency JEM lines), the feature likelihoods break the tie and keep the identities attached to the correct trajectories through the crossing. Conversely, *correct* association keeps each track's feature stream pure — feeding the class recursion above clean, consistent looks — whereas a single mis-association injects a foreign feature and corrupts the class estimate. The two estimation problems reinforce each other: this is why "joint tracking and classification" outperforms doing either in isolation. *(practical)*

**Class-conditioned kinematics close the loop.** Identity also constrains *motion*. An airliner does not pull 9 g; a fighter can. So the class belief can select (or weight) the process-noise level $Q$ and the maneuver model (n7-kinematic): a track believed to be an airliner uses a tight constant-velocity model with small $Q$; a track believed to be a fighter widens $Q$ or adds a coordinated-turn / Singer model. This is the cleanest expression of the coupling — the *discrete* class estimate parameterizes the *continuous* kinematic filter, and the kinematic innovations (a target that just pulled 7 g) feed back as evidence into the class likelihood ("that was no airliner"). In the limit this becomes a joint IMM-over-classes: a bank of (class, motion-model) hypotheses, each carrying its own $x$, $P$, $F$, $Q$, $H$, $R$, mixed by both the kinematic Markov chain (maneuver switching) and the near-static class chain (identity). The features used in practice form a hierarchy of cost and reliability: **RCS amplitude** (free, every dwell, but fluctuates wildly with aspect — Swerling), **JEM** (requires coherent processing, gives engine/blade signatures that strongly discriminate aircraft type and even propeller vs jet), **HRR profiles** (need wideband waveforms, resolve target length and scatterer layout), and **kinematic features** themselves (speed envelope, altitude band, turn capability — a Mach-2 target at 60,000 ft is not a helicopter). The art is fusing these heterogeneous, differently-reliable feature likelihoods into the single $p(f_k\mid c)$ that drives the recursion — which is exactly the "likelihood functions are the common currency" principle from Bayesian tracking, now applied to identity rather than position.


**Q:** In feature-aided tracking, target class is treated as what kind of state, and what estimator maintains a belief over it?

**A:** A hidden discrete state — a finite-alphabet label (e.g. fighter/airliner/helicopter/clutter) that is never observed directly. It is estimated by a discrete Bayes recursion that maintains a posterior probability mass function μ_c over the classes, updated from feature measurements.

**Q:** Name three radar feature types used for target typing and give a one-phrase description of each.

**A:** RCS (radar cross section): return amplitude, varies with target size and aspect. JEM (jet engine modulation): periodic spectral lines from rotating turbine/propeller blades, indicating engine/aircraft type. HRR profile (high-range-resolution): a 1-D image of scattering centers along the line of sight, revealing target length and structure.

**Q:** Write the discrete Bayes recursion that updates the class posterior μ_c(k) from a feature f_k, and identify the role of the confusion matrix.

**A:** μ_c(k) = p(f_k | class=c) · μ_c(k-1) / C, with C = Σ_{c'} p(f_k | c') μ_{c'}(k-1) the normalizer. For a discrete classifier output, the likelihood p(f_k | c) = P(declared label | true class c) is exactly a confusion-matrix entry, estimated offline from labelled data.

**Q (cloze):** Class estimation is structurally an IMM (n10) whose modes are ____ rather than maneuver models, and whose Markov transition matrix is ____ because target type is essentially ____.

**A:** Class estimation is structurally an IMM (n10) whose modes are **target identities/types** rather than maneuver models, and whose Markov transition matrix is **the identity (or near-identity with a tiny leak)** because target type is essentially **static / does not change over time**.

**Q:** State the bidirectional coupling at the heart of feature-aided tracking: how does classification help association, and how does association help classification?

**A:** Classification helps association: the joint measurement-to-track likelihood is multiplied by a feature term (Σ_c μ_c p(f|c)), so a measurement whose feature matches the track's established type is favored and a contradicting one penalized — breaking ties that kinematics alone cannot. Association helps classification: correct measurement-to-track pairing keeps each track's feature stream pure, feeding the class recursion clean looks, whereas a mis-association injects a foreign feature and corrupts the class estimate.

**Q:** Two aircraft cross at the same point so both detections fall in both tracks' gates. Why does a kinematics-only tracker risk an identity swap, and how does feature-aided tracking prevent it?

**A:** At the crossing the kinematic geometry is symmetric: both measurements are equally Gaussian-likely under both tracks, so the association (and JPDA's combined estimates) cannot tell which detection belongs to which trajectory — the classic coalescence/identity-swap failure. Feature-aided tracking adds the feature likelihood: if one track has accumulated 'helicopter' and the other 'jet', the feature terms favor the matching measurement and keep each identity attached to its correct trajectory through the crossing.

**Q:** Why is committing hard to a class after a single feature look dangerous, and what design choice in the class recursion guards against an early wrong commitment? Use RCS fluctuation in your answer.

**A:** RCS fluctuates strongly scan-to-scan with aspect (the Swerling phenomenon), so one look can be an unrepresentative glint — e.g. an airliner momentarily returning a low RCS, or a fighter glinting high. A hard commitment locks in that possibly-wrong label and discards all later contradicting evidence (a degenerate posterior with a zero entry can never recover under pure multiplication). The guard is to keep the class posterior soft and use a near-identity Markov transition matrix with a small leak (or a floor on each μ_c), so the recursion can still admit later evidence and migrate to the correct class as features accumulate.

**Q:** How does the discrete class estimate feed back into the continuous kinematic filter? Give the mechanism and an example.

**A:** The class belief parameterizes the kinematic model: it selects or weights the process noise Q and the maneuver model. A track believed to be an airliner uses a tight constant-velocity model with small Q, while a track believed to be a fighter widens Q or switches to a coordinated-turn/Singer maneuver model. Conversely, an observed hard maneuver (e.g. a 7 g pull) feeds back as class evidence against 'airliner'.

**Q:** When the class estimate and the kinematic filter are fully coupled, what limiting joint estimator does the architecture become?

**A:** A joint IMM over (class, motion-model) hypotheses: a bank of filters, each a (class, maneuver-model) pair carrying its own x, P, F, Q, H, R, mixed by two Markov chains — the kinematic maneuver chain (frequent switching) and the near-static identity/class chain (almost never switching).


## Capstone: designing a full tracker — architecture, model and association choice, NIS/NEES-driven tuning

*Ties the whole ladder into engineering judgment: pick an architecture (centralized vs distributed + covariance intersection), a motion model (CV/CA/CT/Singer or IMM) sized to the target class, an association strategy (GNN vs JPDA vs MHT) by clutter density and target spacing, the right coordinate/measurement frame, and then close the loop with a NIS/NEES-driven tuning protocol — plus a catalog of common failure modes and how to diagnose them.*

Every node before this one taught a *mechanism*. This node teaches *judgment*: given a real sensor, a real target class, and a real clutter environment, how do you assemble those mechanisms into a tracker that works — and, just as important, how do you know it works? The honest summary of the whole field is that there is no universally best tracker; there is only the tracker matched to *your* operating point. Design is the disciplined act of locating that operating point and choosing the cheapest architecture that survives it.

**Start by writing down the operating point, not the algorithm.** Before choosing GNN or an IMM or a coordinate frame, quantify five numbers, because every downstream choice is a function of them. (1) **Detection probability** $P_D$ — fraction of scans on which a real target produces a detection. (2) **Clutter / false-alarm density** $\lambda$ — expected number of spurious detections per unit volume per scan. (3) **Target spacing relative to measurement uncertainty** — how many innovation-covariance ($S$) widths separate neighbouring targets. (4) **Target dynamics** — the maximum acceleration / turn rate the target class exhibits, in units of the position measurement noise per sampling interval. (5) **Revisit rate / sampling interval** $T$ and timing jitter. Blackman & Popoli's *Design and Analysis of Modern Tracking Systems* (Artech House, 1999) organizes the entire design process around exactly these drivers, and MathWorks' tracking toolbox documentation enumerates the same family — target/detection density, $P_D$, sensor resolution, false-alarm rate, and the combinatorial growth of assignment — as the factors that complicate association. If you cannot state these five numbers, you are not ready to choose an algorithm; you are guessing.

**Architecture: centralized measurement fusion vs distributed track-to-track (rung from n6-fusion).** A centralized architecture feeds *raw detections* from every sensor into one filter. It is statistically optimal — no information is discarded, no double-counting — but it demands high-bandwidth links, tight time registration (n5-timereg), and a single point of failure. A distributed architecture lets each sensor run its own local tracker and fuses *tracks*. It is robust, bandwidth-cheap, and modular, but it creates the **common-process-noise correlation problem**: two local tracks of the same target share the same true trajectory and the same process noise, so their errors are correlated by an *unknown* amount. Naively fusing them as if independent makes the fused covariance $P$ too small — the filter becomes overconfident and diverges. The standard defensive tool is **Covariance Intersection (CI)**, from Julier & Uhlmann, *"A Non-Divergent Estimation Algorithm in the Presence of Unknown Correlations,"* Proc. American Control Conference, 1997 (pp. 2369–2373). CI fuses two estimates $(\hat{x}_1,P_1)$ and $(\hat{x}_2,P_2)$ as $P_f^{-1} = \omega P_1^{-1} + (1-\omega)P_2^{-1}$, $P_f^{-1}\hat{x}_f = \omega P_1^{-1}\hat{x}_1 + (1-\omega)P_2^{-1}\hat{x}_2$, with $\omega\in[0,1]$ chosen (usually) to minimize $\det P_f$ or $\mathrm{tr}\,P_f$. Its guarantee: the fused covariance is *consistent* (never optimistic) for **any** true correlation. You pay for that guarantee with conservatism — CI is suboptimal when the inputs really are independent. *(practical)* The rule of thumb: centralize when you own the timing and the pipe; distribute when sensors are geographically scattered, intermittently connected, or built by different vendors — and reach for CI the moment you fuse tracks rather than measurements.

**Motion model: size $Q$ to the target class (rung from n7-kinematic).** A constant-velocity (CV) model with a small white-noise-acceleration $Q$ tracks airliners and ships beautifully and rejects clutter tightly because its validation gate stays small. The same filter loses a fighter the instant it pulls 5 g, because the maneuver acceleration is unmodeled and shows up as a sustained bias in the innovation $\nu = z - H\hat{x}$ — the gate slides off the target. You have three escalating responses. (a) **Inflate $Q$** so the gate is always big enough for the worst maneuver — but a fat $Q$ means a fat $S$, which means a fat gate, which means more clutter admitted and worse accuracy when the target is *not* maneuvering. (b) Use a **single richer model** — constant-acceleration (CA), coordinated-turn (CT), or **Singer** (Robert A. Singer, *"Estimating Optimal Tracking Filter Performance for Manned Maneuvering Targets,"* IEEE Trans. Aerospace and Electronic Systems, vol. AES-6, no. 4, pp. 473–483, July 1970), which models acceleration as a first-order Gauss-Markov process with a correlation time $\tau$ and a maneuver variance $\sigma_m^2$. (c) Use an **IMM** (rung from n10-imm; Blom & Bar-Shalom, IEEE Trans. Automatic Control, vol. 33, no. 8, pp. 780–783, 1988) — a bank of models (e.g. CV + CT) whose Markov-mixed output is tight during cruise and agile during the turn, giving you the best of both at roughly $n_{\text{models}}\times$ the cost of one filter. *(practical)* Decision rule: if the target class spends most of its life in one regime and only occasionally transitions, a single model with well-chosen $Q$ is enough; if it routinely alternates between benign and aggressive dynamics (combat aircraft, evasive vehicles, agile drones), an IMM repays its cost many times over.

**Association: choose by clutter density × target spacing (rungs from n8-gnn / n8-jpda / n9).** This is the axis most often gotten wrong. Place your scenario on a 2-D map — clutter density on one axis, target-to-target spacing (in units of $S$) on the other.
- **Global Nearest Neighbour (GNN)** — one hard assignment per scan, solved with Hungarian/auction. Cheapest, simplest, and *adequate when targets are well separated and clutter is light*. It commits irrevocably each scan, so a single wrong assignment in dense traffic or heavy clutter propagates and can swap or lose tracks.
- **JPDA** — soft, probability-weighted combined innovation across all gated measurements. *Excels when $P_D<1$ and clutter is moderate-to-heavy but the number of targets is known and roughly fixed*. Its classic failure is **track coalescence**: two closely spaced parallel tracks get pulled toward each other because each absorbs a weighted share of the other's measurement.
- **MHT** (Reid, *"An Algorithm for Tracking Multiple Targets,"* IEEE Trans. Automatic Control, vol. 24, no. 6, pp. 843–854, 1979; variants in n9) — **defers** the association decision, propagating multiple hypotheses across scans until evidence disambiguates. *Best — often the only thing that works — when clutter is dense AND targets are closely spaced AND tracks initiate/terminate freely.* Cost is the highest; you control it with N-scan pruning, clustering, and gating. *(practical)* Engineer's heuristic: light clutter + wide spacing → GNN; moderate clutter + known target count + missed detections → JPDA / JIPDA; dense clutter + closely spaced + unknown target count → track-oriented MHT. Don't pay for MHT's combinatorics if GNN's operating point covers you.

**Coordinate & measurement choices (rungs from n5-frames / n5-measmodels).** Filter in a frame where the *motion* is closest to linear (typically a local Cartesian ENU/NED), and put the nonlinearity in the *measurement* model $h(\cdot)$ where an EKF/UKF (n4) can handle it. A radar measures range, azimuth, and Doppler; the dynamics are linear in Cartesian but the measurement is nonlinear — so a CV/CT filter in ENU with a nonlinear $h$ and a UKF update is the textbook pairing. Resist the temptation to convert measurements to Cartesian and run a linear KF: the converted-measurement covariance $R$ becomes range- and angle-dependent and correlated, and getting it wrong is a leading cause of silent inconsistency.

**Worked example — picking $Q$ from physics, then earning it back with NIS/NEES.** Suppose a 2-D radar, $T=1$ s, range-error 30 m, so position measurement noise $\sigma_z\approx 30$ m. Targets are commercial aircraft cruising but occasionally turning, with un-modeled accelerations up to roughly $a_{\max}\approx 20\,\mathrm{m/s^2}$. Use a CV model with discrete white-noise acceleration: per axis $Q = \sigma_a^2\begin{bmatrix}T^4/4 & T^3/2\\ T^3/2 & T^2\end{bmatrix}$. A common rule of thumb sets $\sigma_a$ to roughly $\tfrac{1}{2}$ to $1\times$ the maximum un-modeled acceleration: take $\sigma_a=10\,\mathrm{m/s^2}$. With $T=1$: $Q=100\cdot\begin{bmatrix}0.25 & 0.5\\ 0.5 & 1\end{bmatrix}=\begin{bmatrix}25 & 50\\ 50 & 100\end{bmatrix}$ (units: $\mathrm{m^2}$ for position, $\mathrm{m^2/s}$ off-diagonal, $\mathrm{m^2/s^2}$ for velocity). Now you *test* the choice rather than trust it. The state dimension is $n=4$ (x, vx, y, vy) and the measurement dimension is $m=2$. Run the filter and compute the **NIS** $\epsilon_\nu(k)=\nu(k)^\top S(k)^{-1}\nu(k)$, which under a consistent filter is $\chi^2$ with $m=2$ dof, so its expectation is $2$. Average over, say, $N=50$ scans (or Monte-Carlo runs): the time-averaged NIS, multiplied by $N$, is $\chi^2$ with $Nm$ dof, so the *average* lies in $[\,\chi^2_{Nm}(0.025)/N,\ \chi^2_{Nm}(0.975)/N\,]$. For $N=50,\ m=2$ ($Nm=100$ dof) the two-sided 95% bounds are $\chi^2_{100}\in[74.2,\,129.6]$, so dividing by $50$ the acceptance region for the average is $[1.48,\,2.59]$. If your measured average NIS is, say, $4.1$ — well above $2.59$ — the filter is *optimistic*: $S$ is too small, the gate is too tight, and you are about to lose maneuvering targets. The cure is to *increase* $Q$ (or $R$). Bump $\sigma_a$ to $15\,\mathrm{m/s^2}$, re-run, and watch NIS settle into the band. Conversely, an average NIS far below $1.48$ means the filter is *pessimistic* (over-fat $Q$), admitting clutter and wasting accuracy; shrink $Q$. **NIS uses only the innovation (measurements)**, so it works on live data with no ground truth — your field-tuning tool. **NEES** $\epsilon_x(k)=\tilde{x}(k)^\top P(k)^{-1}\tilde{x}(k)$, with $\tilde{x}=x_{\text{true}}-\hat{x}$, is $\chi^2$ with $n=4$ dof (expectation $4$) and needs ground truth, so it is your *simulation* tool — it catches inconsistency NIS can miss because it interrogates the full state, including unobserved velocity. The disciplined loop: tune $Q,R$ in simulation against NEES *and* NIS, then verify NIS alone holds on real data. This NEES/NIS protocol traces directly to Bar-Shalom, Li & Kirubarajan's consistency framework (*Estimation with Applications to Tracking and Navigation*, Wiley, 2001) and is the standard auto-tuning objective in the modern literature.

**Common failure modes and how you diagnose them — the design payoff.** A tracker that ships is a tracker whose failure modes you can name and instrument. (i) **Filter divergence / overconfidence:** $P$ shrinks, the gate collapses, the track drifts off the target and never recovers. Diagnose with rising NIS/NEES above the $\chi^2$ band; cure with larger $Q$, the Joseph-form covariance update (n3) for numerical safety, or fading-memory. (ii) **Lost track on maneuver:** sustained one-sided innovation $\nu$ during the turn — the model is too stiff; switch to IMM or inflate $Q$. (iii) **Track coalescence / merging:** two parallel tracks collapse into one — a JPDA signature; cure with coalescence-avoidance JPDA (e.g. JPDA*) or move to MHT. (iv) **Track swap:** identities exchange when targets cross — an association failure under tight spacing; defer the decision (MHT) or add a feature/attribute discriminant (n11-typing). (v) **Track fragmentation / redundant tracks:** one target carries several track IDs — initiation thresholds too loose or gating too tight; retune M-of-N / track-score (n11-trackmgmt). (vi) **Clutter-induced false tracks:** confirmation too eager for the measured $\lambda$; raise the SPRT / score deletion thresholds. To *measure* all of this end-to-end against truth, use the **OSPA metric** (Schuhmacher, Vo & Vo, *"A Consistent Metric for Performance Evaluation of Multi-Object Filters,"* IEEE Trans. Signal Processing, vol. 56, no. 8, pp. 3447–3457, 2008), which fuses a **localization** error and a **cardinality** error (wrong number of tracks) into one number — and whose label-aware extensions penalize swaps and fragmentation, exactly the failures above. *(historical and accurate)* That these methods are not academic toys is shown by their deployment: the Sea-Based X-Band Radar (SBX-1) arrived at Pearl Harbor in January 2006 and was fielded with the Missile Defense Agency that year as part of the Pacific Ballistic Missile Defense System, performing precisely the dense-environment task — discriminating warheads from decoys and debris and maintaining precise tracks — that multiple-hypothesis methods (Reid's MHT, 1979) were invented to solve more than two decades earlier. *(metaphorical)* Think of the whole design as choosing a vehicle for terrain you have surveyed: GNN is a bicycle (cheap, fast, fine on open road), JPDA is an all-weather sedan (handles rain and crowds), MHT is an off-road expedition truck (expensive, slow, the only thing that crosses the swamp) — and the NIS/NEES loop is the dashboard that tells you whether you're about to run out of road. Pick the cheapest vehicle that crosses *your* terrain, instrument the dashboard, and re-tune when the readings leave the band.


**Q:** Before choosing any tracking algorithm, what five quantities define the 'operating point' that every design choice depends on?

**A:** Detection probability P_D; clutter / false-alarm density λ; target spacing relative to the innovation-covariance S width; target dynamics (max acceleration/turn rate vs measurement noise); and revisit rate / sampling interval T (with timing jitter).

**Q:** In a distributed track-to-track fusion architecture, why does naively fusing two local tracks of the same target as if they were independent make the filter diverge?

**A:** The two tracks share the same true trajectory and the same process noise, so their errors are correlated by an unknown amount; treating them as independent double-counts information and shrinks the fused covariance P too small, making the filter overconfident and prone to divergence.

**Q:** State the Covariance Intersection fusion equations (information form) for two estimates (x̂₁,P₁) and (x̂₂,P₂), and name the consistency property they guarantee.

**A:** P_f⁻¹ = ω P₁⁻¹ + (1−ω) P₂⁻¹ and P_f⁻¹ x̂_f = ω P₁⁻¹ x̂₁ + (1−ω) P₂⁻¹ x̂₂, with ω∈[0,1] (typically chosen to minimize det P_f or tr P_f). They guarantee a consistent (never optimistic) fused covariance for ANY true correlation between the inputs.

**Q:** Two surface targets travel parallel tracks separated by only ~1.5 innovation-covariance widths, in moderate clutter, with the number of targets known and fixed. Which association strategy is the textbook fit, and what is its characteristic failure to watch for?
  a) GNN — but watch for irrevocable wrong assignments
  b) JPDA — but watch for track coalescence (parallel tracks pulled together)
  c) Track-oriented MHT — but watch for hypothesis explosion
  d) Pure prediction without association — but watch for drift

**A:** JPDA — but watch for track coalescence (parallel tracks pulled together) — Known/fixed target count with missed detections and moderate clutter is JPDA's sweet spot (soft probability-weighted combined innovation). Its signature failure with closely spaced parallel targets is coalescence: each track absorbs a weighted share of the other's measurement and they are pulled together. GNN's hard commitment risks swaps here; MHT would work but is overkill for a known fixed count in only moderate clutter.

**Q:** Why does GNN succeed but MHT becomes worth its cost as you move from light-clutter/well-separated targets to dense-clutter/closely-spaced targets with unknown target count?

**A:** GNN makes one irrevocable hard assignment per scan; when targets are well separated and clutter is light there is rarely ambiguity, so committing immediately is correct and cheap. As clutter density rises and spacing shrinks, each scan's correct assignment becomes ambiguous, and an early hard commitment propagates errors (swaps, lost tracks). MHT instead DEFERS the decision, carrying multiple hypotheses across scans until later evidence disambiguates — which is exactly what dense, closely spaced, variable-cardinality scenes require — at the price of combinatorial hypothesis growth controlled by N-scan pruning and clustering.

**Q (cloze):** Fill in: NIS = νᵀ S⁻¹ ν is χ² with ____ degrees of freedom and uses ____, so it can be checked on live data with no ground truth; NEES = x̃ᵀ P⁻¹ x̃ is χ² with ____ degrees of freedom and requires ____, so it is a simulation tool.

**A:** Fill in: NIS = νᵀ S⁻¹ ν is χ² with **m (the measurement dimension)** degrees of freedom and uses **only the innovation / measurements**, so it can be checked on live data with no ground truth; NEES = x̃ᵀ P⁻¹ x̃ is χ² with **n (the state dimension)** degrees of freedom and requires **ground truth (the true state)**, so it is a simulation tool.

**Q:** A radar tracker's time-averaged NIS over N=50 scans comes out at 4.1 when the measurement dimension is m=2 (expected average ≈2, two-sided 95% band ≈[1.48, 2.59], i.e. χ²₁₀₀∈[74.2,129.6] divided by 50). What is the filter doing wrong, and what is the corrective action?

**A:** Average NIS far above the upper bound (4.1 ≫ 2.59) means the innovation covariance S is too small relative to the actual innovations — the filter is OPTIMISTIC/overconfident, its gate is too tight, and it will lose maneuvering targets. The fix is to increase the assumed uncertainty: enlarge Q (e.g. raise the white-noise-acceleration σ_a) and/or R until the averaged NIS falls back inside the χ² band.

**Q:** Given a CV model with discrete white-noise acceleration, per-axis Q = σ_a²·[[T⁴/4, T³/2],[T³/2, T²]], compute Q for T=1 s and σ_a=10 m/s².

**A:** Q = 100·[[0.25, 0.5],[0.5, 1]] = [[25, 50],[50, 100]] (units: m² position, m²/s off-diagonal, m²/s² velocity).

**Q:** What two error components does the OSPA metric combine into a single multi-target tracking score?

**A:** A localization (state-estimation distance) error component and a cardinality error component (penalizing the wrong number of tracks versus truth).

**Q:** A confirmed track on a fighter shows the innovation ν staying one-sided (consistently positive in the down-range axis) for several scans, after which the gate slides off the target and the track is lost. Which diagnosis and cure fit best?
  a) Track coalescence; switch to coalescence-avoiding JPDA
  b) Model too stiff for the maneuver (unmodeled acceleration as a sustained innovation bias); switch to an IMM or inflate Q
  c) Clutter-induced false track; raise SPRT/track-score thresholds
  d) Numerical loss of symmetry in P; switch to Joseph-form update

**A:** Model too stiff for the maneuver (unmodeled acceleration as a sustained innovation bias); switch to an IMM or inflate Q — A SUSTAINED, one-sided (biased) innovation during a turn is the classic signature of an unmodeled maneuver: a stiff CV model cannot represent the acceleration, so it leaks out as a persistent innovation bias and the gate drifts off-target. The cure is a richer/adaptive dynamics model — an IMM (e.g. CV+CT) or, minimally, a larger Q. Coalescence is about parallel tracks merging, false tracks are an initiation/score problem, and Joseph form addresses numerical (not dynamical) inconsistency.
