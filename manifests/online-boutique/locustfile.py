#!/usr/bin/python
#
# Load profile for the Online Boutique load generator.
#
# Derived from the upstream locustfile (src/loadgenerator/locustfile.py in
# GoogleCloudPlatform/microservices-demo) and mounted over it by the Helm
# post-renderer (see manifests/helm-plugins/ob-frontend-image/post-render.sh).
#
# Differences from upstream, all deliberate:
#   * users think for 1-3 s instead of 1-10 s, so the same USERS count drives
#     roughly three times the request rate;
#   * the mix is weighted towards the product and cart pages. Those are the
#     surfaces where a frontend regression in backend fan-out (extra catalog
#     lookups per page, N+1 patterns) shows up first, so a bad release moves
#     the dashboard immediately instead of being averaged away by cheap
#     requests such as /setCurrency;
#   * requests are named by route so the load generator's own log lines can
#     be grouped the same way Linkerd's ServiceProfile routes are.
#
# USERS and RATE are still read from the environment by the image's
# entrypoint; set LOADGEN_USERS / LOADGEN_RATE in .env.

import datetime
import random

from faker import Faker
from locust import FastHttpUser, TaskSet, between

fake = Faker()

products = [
    '0PUK6V6EV0',
    '1YMWWN1N4O',
    '2ZYFJ3GM2N',
    '66VCHSJNUP',
    '6E92ZMYYFZ',
    '9SIQT8TOJO',
    'L9ECAV7KIM',
    'LS4PSXUNUM',
    'OLJCESPC7Z',
]


def index(l):
    l.client.get("/")


def setCurrency(l):
    currencies = ['EUR', 'USD', 'JPY', 'CAD', 'GBP', 'TRY']
    l.client.post("/setCurrency", {'currency_code': random.choice(currencies)})


def browseProduct(l):
    l.client.get("/product/" + random.choice(products), name="/product/[id]")


def viewCart(l):
    l.client.get("/cart")


def addToCart(l):
    product = random.choice(products)
    l.client.get("/product/" + product, name="/product/[id]")
    l.client.post("/cart", {
        'product_id': product,
        'quantity': random.randint(1, 10),
    })


def empty_cart(l):
    l.client.post('/cart/empty')


def checkout(l):
    addToCart(l)
    current_year = datetime.datetime.now().year + 1
    l.client.post("/cart/checkout", {
        'email': fake.email(),
        'street_address': fake.street_address(),
        'zip_code': fake.zipcode(),
        'city': fake.city(),
        'state': fake.state_abbr(),
        'country': fake.country(),
        'credit_card_number': fake.credit_card_number(card_type="visa"),
        'credit_card_expiration_month': random.randint(1, 12),
        'credit_card_expiration_year': random.randint(current_year, current_year + 70),
        'credit_card_cvv': f"{random.randint(100, 999)}",
    })


def logout(l):
    l.client.get('/logout')


class UserBehavior(TaskSet):

    def on_start(self):
        index(self)

    tasks = {
        index: 3,
        setCurrency: 1,
        browseProduct: 12,
        addToCart: 3,
        viewCart: 5,
        checkout: 1,
    }


class WebsiteUser(FastHttpUser):
    tasks = [UserBehavior]
    wait_time = between(1, 3)
